pub const segment = @import("segment.zig");
pub const control = @import("control.zig");
pub const data = @import("data.zig");

// Re-export commonly used functions
pub const sendSegment = segment.sendSegment;
pub const sendSyn = control.sendSyn;
/// sendSynAck: retransmit SYN-ACK without explicit peer options (uses TCB-stored options).
pub fn sendSynAck(tcb: *@import("../types.zig").Tcb) bool {
    return control.sendSynAckWithOptions(tcb, null);
}
pub const sendSynAckWithOptions = control.sendSynAckWithOptions;
pub const sendAck = control.sendAck;
pub const sendFin = control.sendFin;
pub const sendRst = control.sendRst;
pub const sendRstForPacket = control.sendRstForPacket;
pub const sendRstForPacket6 = control.sendRstForPacket6;
pub const calculateSegmentLength = data.calculateSegmentLength;
pub const transmitPendingData = data.transmitPendingData;
pub const retransmitLoss = data.retransmitLoss;
