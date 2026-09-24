import { ChildProcess, spawn } from 'node:child_process';
import {
    createWriteStream,
    existsSync,
    mkdirSync,
    readFileSync,
    renameSync,
    rmSync,
    statSync,
    WriteStream,
    writeFileSync,
} from 'node:fs';
import { dirname } from 'node:path';

import { Injectable, Logger, OnModuleInit } from '@nestjs/common';

import { IXrayProcessStatus, XrayProcessService } from './xray-process.service';

const CORE_LINK = '/usr/local/bin/rw-core';
const LOG_FILE = '/var/log/xray/current';
const LOG_MAX_BYTES = 10 * 1024 * 1024;

const KILL_AFTER_MS = 3_000;
const DOWN_TIMEOUT_MS = 10_000;
const UP_TIMEOUT_MS = 10_000;

interface IExitInfo {
    code: number | null;
    signal: NodeJS.Signals | null;
    at: number;
}

/**
 * Supervises Xray as a direct child process, for hosts without s6-overlay
 * (plain VMs, LXC containers). Mirrors the s6 semantics the node relies on:
 * `start` is "up once" (no auto-restart), `stop` sends SIGTERM and escalates
 * to SIGKILL, and output goes to the same log file s6-log would write.
 *
 * Enabled with XRAY_PROCESS_MANAGER=native.
 */
@Injectable()
export class NativeXrayProcessService extends XrayProcessService implements OnModuleInit {
    private readonly nativeLogger = new Logger(NativeXrayProcessService.name);

    private readonly pidFile: string;

    private child: ChildProcess | null = null;
    private startedAt = 0;
    private lastExit: IExitInfo | null = null;

    private logStream: WriteStream | null = null;
    private logBytes = 0;

    constructor() {
        super();

        this.pidFile = `${process.env.REMNANODE_RUN_DIR ?? '/run/remnanode'}/xray.pid`;
    }

    public onModuleInit(): void {
        this.killStaleProcess();

        process.once('exit', () => {
            if (this.isAlive()) this.child?.kill('SIGKILL');
        });
    }

    public override isControlAvailable(): boolean {
        if (existsSync(CORE_LINK)) return true;

        this.nativeLogger.error(`${CORE_LINK} not found`);
        return false;
    }

    public override async start(): Promise<void> {
        if (this.isAlive()) return;

        const socketPath = process.env.INTERNAL_SOCKET_PATH;
        const token = process.env.INTERNAL_REST_TOKEN;

        if (!socketPath || !token) {
            throw new Error('INTERNAL_SOCKET_PATH or INTERNAL_REST_TOKEN is not set');
        }

        const { SECRET_KEY: _secretKey, ...env } = process.env;

        const child = spawn(
            CORE_LINK,
            ['-config', `@${socketPath}:/internal/get-config?token=${token}`, '-format', 'json'],
            { env, stdio: ['ignore', 'pipe', 'pipe'] },
        );

        await new Promise<void>((resolve, reject) => {
            const timer = setTimeout(() => {
                child.kill('SIGKILL');
                reject(new Error(`xray did not spawn within ${UP_TIMEOUT_MS}ms`));
            }, UP_TIMEOUT_MS);

            child.once('spawn', () => {
                clearTimeout(timer);
                resolve();
            });
            child.once('error', (error) => {
                clearTimeout(timer);
                reject(error);
            });
        });

        this.child = child;
        this.startedAt = Date.now();
        this.lastExit = null;

        this.openLog();
        child.stdout?.on('data', (chunk: Buffer) => this.writeLog(chunk));
        child.stderr?.on('data', (chunk: Buffer) => this.writeLog(chunk));

        child.once('exit', (code, signal) => {
            this.lastExit = { code, signal, at: Date.now() };
            this.removePidFile();
            this.nativeLogger.log(
                `Xray process ${child.pid} exited (code: ${code ?? '-'}, signal: ${signal ?? '-'})`,
            );
        });

        this.writePidFile(child.pid);
    }

    public override async stop(): Promise<void> {
        const child = this.child;

        if (!child || !this.isAlive()) return;

        const exited = new Promise<void>((resolve) => child.once('exit', () => resolve()));

        child.kill('SIGTERM');

        const killTimer = setTimeout(() => {
            if (this.isAlive()) child.kill('SIGKILL');
        }, KILL_AFTER_MS);

        let downTimer: NodeJS.Timeout | undefined;

        try {
            await Promise.race([
                exited,
                new Promise<never>((_, reject) => {
                    downTimer = setTimeout(
                        () => reject(new Error(`xray did not stop within ${DOWN_TIMEOUT_MS}ms`)),
                        DOWN_TIMEOUT_MS,
                    );
                }),
            ]);
        } finally {
            clearTimeout(killTimer);
            clearTimeout(downTimer);
        }
    }

    public override async getStatus(): Promise<IXrayProcessStatus> {
        const up = this.isAlive();
        const pid = up ? (this.child?.pid ?? null) : null;

        return { up, pid, raw: `${up} ${pid ?? -1}` };
    }

    public override async getStatusLine(): Promise<string> {
        if (this.isAlive()) {
            const seconds = Math.round((Date.now() - this.startedAt) / 1000);
            return `up (pid ${this.child?.pid}) ${seconds} seconds`;
        }

        if (this.lastExit) {
            const seconds = Math.round((Date.now() - this.lastExit.at) / 1000);
            const reason = this.lastExit.signal
                ? `signal ${this.lastExit.signal}`
                : `exitcode ${this.lastExit.code}`;
            return `down (${reason}) ${seconds} seconds`;
        }

        return 'down (never started)';
    }

    private isAlive(): boolean {
        return !!this.child && this.child.exitCode === null && this.child.signalCode === null;
    }

    private openLog(): void {
        if (this.logStream) return;

        try {
            mkdirSync(dirname(LOG_FILE), { recursive: true });
            this.logBytes = existsSync(LOG_FILE) ? statSync(LOG_FILE).size : 0;
            this.logStream = createWriteStream(LOG_FILE, { flags: 'a' });
            this.logStream.on('error', (error) => {
                this.nativeLogger.warn(`Xray log stream error: ${error}`);
                this.logStream = null;
            });
        } catch (error) {
            this.nativeLogger.warn(`Failed to open ${LOG_FILE}: ${error}`);
        }
    }

    private writeLog(chunk: Buffer): void {
        if (!this.logStream) return;

        this.logBytes += chunk.length;
        this.logStream.write(chunk);

        if (this.logBytes < LOG_MAX_BYTES) return;

        this.logStream.end();
        this.logStream = null;

        try {
            renameSync(LOG_FILE, `${LOG_FILE}.1`);
        } catch (error) {
            this.nativeLogger.warn(`Failed to rotate ${LOG_FILE}: ${error}`);
        }

        this.openLog();
    }

    private writePidFile(pid: number | undefined): void {
        if (!pid) return;

        try {
            mkdirSync(dirname(this.pidFile), { recursive: true, mode: 0o700 });
            writeFileSync(this.pidFile, String(pid));
        } catch (error) {
            this.nativeLogger.warn(`Failed to write ${this.pidFile}: ${error}`);
        }
    }

    private removePidFile(): void {
        rmSync(this.pidFile, { force: true });
    }

    /**
     * A previous node instance that died without cleanup (OOM, SIGKILL) leaves
     * its Xray running with the ports still bound. Kill it, but only if the pid
     * still belongs to an Xray started by us.
     */
    private killStaleProcess(): void {
        try {
            const pid = Number(readFileSync(this.pidFile, 'utf8').trim());

            if (!Number.isInteger(pid) || pid <= 1) return;

            const argv = readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0');

            if (
                argv[0] !== CORE_LINK ||
                !argv.some((arg) => arg.includes('/internal/get-config'))
            ) {
                return;
            }

            process.kill(pid, 'SIGKILL');
            this.nativeLogger.warn(`Killed stale Xray process ${pid} left by a previous run`);
        } catch {
            // no pid file, or the process is already gone
        } finally {
            this.removePidFile();
        }
    }
}
