// Represents a log message.
export interface LogMessage {
    message: string;
    level: LogLevel;
    context?: Record<string, any>;
}

// An enum value representing a log level.
export enum LogLevel {
    fatal = "fatal",
    error = "error",
    warn = "warn",
    info = "info",
    debug = "debug",
    trace = "trace",
}
