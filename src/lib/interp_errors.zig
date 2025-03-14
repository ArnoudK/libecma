pub const InterpreterError = error{
    TooManyArguments,
    NotCallable,
    NotAnObject,
    NotAnArray,
    IndexOutOfBounds,
    UndefinedVariable,
    NotAString,
    OutOfMemory,
    NoSpaceLeft,
    DiskQuota,
    FileTooBig,
    InputOutput,
    DeviceBusy,
    InvalidArgument,
    AccessDenied,
    BrokenPipe,
    SystemResources,
    OperationAborted,
    NotOpenForWriting,
    LockViolation,
    WouldBlock,
    ConnectionResetByPeer,
    ProcessNotFound,
    NoDevice,
    Unexpected,
    NotImplemented,
    TypeError,
};
