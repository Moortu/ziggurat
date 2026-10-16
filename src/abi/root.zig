//! The host/module ABI: the table a user module returns to the host and the
//! layout stamp both sides compare. Imports only `std` and `builtin`.

const abi = @import("abi.zig");
const validator = @import("validate.zig");

pub const magic = abi.magic;
pub const abi_version = abi.abi_version;
pub const Str = abi.Str;
pub const LogLevel = abi.LogLevel;
pub const HostApi = abi.HostApi;
pub const CallError = abi.CallError;
pub const call_ok = abi.call_ok;
pub const call_invalid_method = abi.call_invalid_method;
pub const call_invalid_argument = abi.call_invalid_argument;
pub const call_too_many_arguments = abi.call_too_many_arguments;
pub const call_too_few_arguments = abi.call_too_few_arguments;
pub const call_instance_is_null = abi.call_instance_is_null;
pub const FieldDesc = abi.FieldDesc;
pub const ArgDesc = abi.ArgDesc;
pub const PropertyDesc = abi.PropertyDesc;
pub const no_field = abi.no_field;
pub const MethodDesc = abi.MethodDesc;
pub const method_flag_virtual = abi.method_flag_virtual;
pub const SignalDesc = abi.SignalDesc;
pub const ScriptDesc = abi.ScriptDesc;
pub const script_flag_tool = abi.script_flag_tool;
pub const Table = abi.Table;
pub const StampInputs = abi.StampInputs;
pub const layoutStamp = abi.layoutStamp;
pub const validate = validator.validate;
pub const Limits = validator.Limits;
pub const ValidateError = validator.ValidateError;

test {
    _ = abi;
    _ = validator;
}
