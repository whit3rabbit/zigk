const std = @import("std");
const console = @import("console");
const hal = @import("hal");

const types = @import("../types.zig");
const device = @import("../device.zig");
const trb = @import("../trb.zig");

pub const TransferError = error{
    Timeout,
    StallError,
    BabbleError,
    TransactionError,
    TrbError,
    SplitTransactionError,
    ResourceError,
    BandwidthError,
    NoSlotsAvailable,
    InvalidStreamType,
    SlotNotEnabled,
    EndpointNotEnabled,
    ShortPacket,
    RingUnderrun,
    RingOverrun,
    VfEventRingFull,
    ParameterError,
    BandwidthOverrun,
    ContextStateError,
    NoPingResponse,
    EventRingFull,
    IncompatibleDevice,
    MissedService,
    CommandRingStopped,
    CommandAborted,
    Stopped,
    StoppedLengthInvalid,
    Reserved,
    IsochBufferOverrun,
    EventLost,
    Undefined,
    InvalidBidirectional,
    InvalidParam,
    RingFull,
    TransferFailed,
    InvalidState,
    OutOfMemory,
};

/// Map TRB completion code to error
pub fn mapCompletionCode(code: trb.CompletionCode) TransferError!void {
    return switch (code) {
        .Success => {},
        .ShortPacket => {}, // Handled by caller checking residual
        .StallError => error.StallError,
        .BabbleDetectedError => error.BabbleError,
        .USBTransactionError => error.TransactionError,
        .TRBError => error.TrbError,
        .SplitTransactionError => error.SplitTransactionError,
        .ResourceError => error.ResourceError,
        .BandwidthError => error.BandwidthError,
        .NoSlotsAvailableError => error.NoSlotsAvailable,
        .InvalidStreamTypeError => error.InvalidStreamType,
        .SlotNotEnabledError => error.SlotNotEnabled,
        .EndpointNotEnabledError => error.EndpointNotEnabled,
        .RingUnderrun => error.RingUnderrun,
        .RingOverrun => error.RingOverrun,
        .VFEventRingFullError => error.VfEventRingFull,
        .ParameterError => error.ParameterError,
        .BandwidthOverrunError => error.BandwidthOverrun,
        .ContextStateError => error.ContextStateError,
        .NoPingResponseError => error.NoPingResponse,
        .EventRingFullError => error.EventRingFull,
        .IncompatibleDeviceError => error.IncompatibleDevice,
        .MissedServiceError => error.MissedService,
        .CommandRingStopped => error.CommandRingStopped,
        .CommandAborted => error.CommandAborted,
        .Stopped => error.Stopped,
        .StoppedLengthInvalid => error.StoppedLengthInvalid,
        .IsochBufferOverrun => error.IsochBufferOverrun,
        .EventLostError => error.EventLost,
        else => {
            console.err("XHCI: Unhandled completion code: {}", .{@intFromEnum(code)});
            return error.Undefined;
        },
    };
}

/// Wait for pending transfer to complete
/// Handles polling if MSI-X is not available
pub fn waitForCompletion(
    ctrl: *types.Controller,
    dev: *device.UsbDevice,
    ep_dci: u5,
    timeout_ms: u64,
) TransferError!u24 {
    const start = hal.timing.rdtsc();
    const freq = hal.timing.getTscFrequency();
    const timeout_ticks = (timeout_ms * freq) / 1000;

    while (device.matchesPendingTransfer(dev.slot_id, ep_dci)) {
        // Poll if no MSI-X
        if (ctrl.msix_vectors == null) {
            if (ctrl.poll_events_fn) |poll| {
                 _ = poll();
            }
        }
        
        hal.cpu.pause();

        // Check timeout
        if (hal.timing.rdtsc() - start > timeout_ticks) {
             console.warn("XHCI: Transfer timed out (slot={}, ep={})", .{dev.slot_id, ep_dci});
             // Clear pending transfer to prevent late completion corruption
             device.clearPendingTransfer();
             return error.Timeout;
        }
    }

    // Transfer completed
    if (device.getPendingTransfer()) |pt| {
         // Mark as inactive
         device.clearPendingTransfer();

         try mapCompletionCode(pt.completion_code);
         // Return residual (bytes NOT transferred). Caller computes actual = requested - residual
         return pt.residual;
    }

    return error.Undefined;
}
