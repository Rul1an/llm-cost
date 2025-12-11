const std = @import("std");

test "probe verifier" {
    const T = std.crypto.sign.Ed25519.Verifier;
    @compileLog("Verifier Decls:", @typeInfo(T).@"struct".decls);
}
