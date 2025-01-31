// Represents a log message.
export interface LogMessage {
    message: string;
    level: LogLevel;
    context?: Record<string, any>;
}

// An enum value representing a log level.
export type LogLevel = "fatal" | "error" | "warn" | "info" | "debug" | "trace";
