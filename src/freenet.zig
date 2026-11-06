//! freenet-zig: write Freenet delegates, contracts and web apps in Zig.
//!
//! Most programs only need the names re-exported here; the submodules hold
//! the details. See README.md and docs/ for guides.

pub const delegate = @import("delegate.zig");
pub const contract = @import("contract.zig");
pub const host = @import("host.zig");
pub const types = @import("types.zig");
pub const webapp = @import("webapp.zig");
pub const testing = @import("testing.zig");
pub const bincode = @import("bincode.zig");
pub const abi = @import("abi.zig");
/// Native programs talking to a node (WebSocket API): get a state, send a delta.
pub const client = @import("client.zig");

// ---- delegates ----
pub const exportDelegate = delegate.exportDelegate;
pub const Delegate = delegate.Delegate;
pub const Inbound = delegate.Inbound;
pub const Origin = delegate.Origin;
pub const UserResponse = delegate.UserResponse;
pub const UserInputRequest = delegate.UserInputRequest;
pub const ContractState = delegate.ContractState;
pub const ContractRequest = delegate.ContractRequest;

// ---- contracts ----
pub const exportContract = contract.exportContract;
pub const Contract = contract.Contract;
pub const ValidateResult = contract.ValidateResult;
pub const UpdateResult = contract.UpdateResult;
pub const Update = contract.Update;
pub const Updates = contract.Updates;
pub const RelatedContracts = contract.RelatedContracts;
pub const RelatedRequest = contract.RelatedRequest;

// ---- host functions ----
pub const random = host.random;
pub const log = host.log;

// ---- identifiers ----
pub const ContractInstanceId = types.ContractInstanceId;
pub const DelegateKey = types.DelegateKey;

/// The signed-site web-app contract `addWebApp` uses.
pub const WebContainer = @import("webcontainer.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
