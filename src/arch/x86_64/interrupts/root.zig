const state = @import("state.zig");
const handlers = @import("handlers.zig");
const irq = @import("irq.zig");
const init_mod = @import("init.zig");

// Re-exports
pub const InterruptFrame = state.InterruptFrame;
pub const GuardPageInfo = state.GuardPageInfo;
pub const MSIX_VECTOR_START = state.MSIX_VECTOR_START;
pub const MSIX_VECTOR_END = state.MSIX_VECTOR_END;
pub const MSIX_VECTOR_COUNT = state.MSIX_VECTOR_COUNT;
pub const MsixVectorAllocation = state.MsixVectorAllocation;

pub const exception_names = handlers.exception_names;
pub const exceptionHandler = handlers.exceptionHandler;
pub const lapicTimerHandler = handlers.lapicTimerHandler;
pub const printFrame = handlers.printFrame;
pub const printHex = handlers.printHex;

pub const irqHandler = irq.irqHandler;
pub const logUnexpectedIrq = irq.logUnexpectedIrq;
pub const allocateMsixVectors = irq.allocateMsixVectors;
pub const allocateMsixVector = irq.allocateMsixVector;
pub const freeMsixVectors = irq.freeMsixVectors;
pub const freeMsixVector = irq.freeMsixVector;
pub const registerMsixHandler = irq.registerMsixHandler;
pub const unregisterMsixHandler = irq.unregisterMsixHandler;
pub const getFreeMsixVectorCount = irq.getFreeMsixVectorCount;
pub const isMsixVectorAllocated = irq.isMsixVectorAllocated;

pub const init = init_mod.init;
pub const registerHandler = init_mod.registerHandler;
pub const setConsoleWriter = init_mod.setConsoleWriter;
pub const setKeyboardHandler = init_mod.setKeyboardHandler;
pub const setMouseHandler = init_mod.setMouseHandler;
pub const setSerialHandler = init_mod.setSerialHandler;
pub const setCrashHandler = init_mod.setCrashHandler;
pub const setTimerHandler = init_mod.setTimerHandler;
pub const setGuardPageChecker = init_mod.setGuardPageChecker;
pub const setFpuAccessHandler = init_mod.setFpuAccessHandler;
pub const setPageFaultHandler = init_mod.setPageFaultHandler;
pub const setGenericIrqHandler = init_mod.setGenericIrqHandler;
