//! The model's and the routines' unit tests: a design compiled with
//! `vera.analyze` (or the digital `run.Harness`), opened, and its rows
//! and failure paths checked. The ABI, the header's constants and C object
//! lifetimes are `zig build test-vpi` (tests/conformance/tests/verilog-ams/ch11_vpi/vpi_app.c against
//! src/vpi/vpi_user.h); the last test here checks every Zig copy of a header
//! constant against the header text.

const std = @import("std");
const Ast = @import("frontend").Ast;
const elab = @import("elab");
const root = @import("vpi");
const callback = root.callback;
const code_tables = root.code_tables;
const user = root.user;
const abi = root.abi;
const session = root.session;
const status = root.status;
const trust = root.trust;
const schema = root.schema;
const delays = root.delays;
const handle = root.handle;
const iterate = root.iterate;
const property = root.property;
const run = root.run;
const systf = root.systf;
const value = root.value;

const ErrorInfo = abi.ErrorInfo;
const Obj = schema.Obj;
const Scope = schema.Scope;
const StartupFn = abi.StartupFn;
const asObj = trust.asObj;
const close = session.close;
const open = session.open;
const runStartupTable = session.runStartupTable;
const vpiArray = user.vpiArray;
const vpiBranch = user.vpiBranch;
const vpiCell = user.vpiCell;
const vpiConfig = user.vpiConfig;
const vpiConstType = user.vpiConstType;
const vpiConstant = user.vpiConstant;
const vpiDefName = user.vpiDefName;
const vpiDirection = user.vpiDirection;
const vpiDiscipline = user.vpiDiscipline;
const vpiError = user.vpiError;
const vpiFlow = user.vpiFlow;
const vpiFullName = user.vpiFullName;
const vpiHandle = abi.vpiHandle;
const vpiIndex = user.vpiIndex;
const vpiInout = user.vpiInout;
const vpiIntConst = user.vpiIntConst;
const vpiIntegerVar = user.vpiIntegerVar;
const vpiIsMemory = user.vpiIsMemory;
const vpiIterator = user.vpiIterator;
const vpiLibrary = user.vpiLibrary;
const vpiLocalParam = user.vpiLocalParam;
const vpiMemory = user.vpiMemory;
const vpiMemoryWord = user.vpiMemoryWord;
const vpiModule = user.vpiModule;
const vpiModuleArray = user.vpiModuleArray;
const vpiName = user.vpiName;
const vpiNature = user.vpiNature;
const vpiNegNode = user.vpiNegNode;
const vpiNet = user.vpiNet;
const vpiNode = user.vpiNode;
const vpiPLI = user.vpiPLI;
const vpiParameter = user.vpiParameter;
const vpiParent = user.vpiParent;
const vpiPort = user.vpiPort;
const vpiPortIndex = user.vpiPortIndex;
const vpiPosNode = user.vpiPosNode;
const vpiPotential = user.vpiPotential;
const vpiQuantity = user.vpiQuantity;
const vpiRealConst = user.vpiRealConst;
const vpiRealVar = user.vpiRealVar;
const vpiReg = user.vpiReg;
const vpiRegArray = user.vpiRegArray;
const vpiScalar = user.vpiScalar;
const vpiScope = user.vpiScope;
const vpiSize = user.vpiSize;
const vpiTopModule = user.vpiTopModule;
const vpiType = user.vpiType;
const vpiUndefined = user.vpiUndefined;
const vpiVarSelect = user.vpiVarSelect;
const vpiVector = user.vpiVector;
const vpi_chk_error = status.vpi_chk_error;
const vpi_compare_objects = trust.vpi_compare_objects;
const vpi_free_object = trust.vpi_free_object;
const vpi_get = property.vpi_get;
const vpi_get_str = property.vpi_get_str;
const vpi_handle = handle.vpi_handle;
const vpi_handle_by_index = handle.vpi_handle_by_index;
const vpi_handle_by_name = handle.vpi_handle_by_name;
const vpi_iterate = iterate.vpi_iterate;
const vpi_release_handle = trust.vpi_release_handle;
const vpi_scan = iterate.vpi_scan;

const vera = @import("vera");
const Time = abi.Time;

/// A three-deep design with something of every answered class at every level.
const nested_src =
    \\module top(p, n);
    \\  inout p, n; electrical p, n;
    \\  parameter real g = 2.0;
    \\  localparam integer tag = 7;
    \\  electrical mid;
    \\  reg [3:0] state;
    \\  sub u(p, n);
    \\  analog I(p,n) <+ g*V(p,n);
    \\endmodule
    \\module sub(a, b);
    \\  inout a, b; electrical a, b;
    \\  parameter real k = 1.0;
    \\  electrical inner;
    \\  reg flag;
    \\  leaf v(a, b);
    \\  analog I(a,b) <+ k*V(a,b);
    \\endmodule
    \\module leaf(x, y);
    \\  inout x, y; electrical x, y;
    \\  parameter real r = 3.0;
    \\  electrical deep;
    \\  analog I(x,y) <+ r*V(x,y);
    \\endmodule
;
var startup_calls: usize = 0;
var probe_starting = false;
var probe_get: c_int = 0;
var probe_refused = false;
var probe_timed: vpiHandle = null;
var probe_compile: vpiHandle = null;

// ---- private ----

fn openSource(src: []const u8) !vera.Result {
    var res = try vera.analyze(std.testing.allocator, src, .{}, null);
    errdefer res.deinit(std.testing.allocator);
    try open(std.testing.allocator, &res);
    return res;
}

fn countStartupCall() callconv(.c) void {
    startup_calls += 1;
}

/// The `Scope` whose §6.7 path is `path`, or a test failure.
fn scopeAt(path: []const u8) !*const Scope {
    for (session.design.?.scopes) |*s| if (std.mem.eql(u8, s.path, path)) return s;
    std.debug.print("no scope at `{s}`\n", .{path});
    return error.TestExpectedEqual;
}

fn noteNothing(_: *abi.CbData) callconv(.c) c_int {
    return 0;
}

fn probeStartup() callconv(.c) void {
    probe_starting = session.starting;
    probe_get = vpi_get(vpiType, null);
    var info: ErrorInfo = undefined;
    _ = vpi_chk_error(&info);
    probe_refused = info.code != null and std.mem.eql(u8, std.mem.span(info.code), "STARTUP");
    var t: abi.Time = .{ .type = user.vpiSimTime, .high = 0, .low = 1, .real = 0 };
    const timed: abi.CbData = .{ .reason = user.cbAfterDelay, .cb_rtn = noteNothing, .obj = null, .time = &t, .value = null, .index = 0, .user_data = null };
    probe_timed = callback.vpi_register_cb(&timed);
    const compiled: abi.CbData = .{ .reason = user.cbEndOfCompile, .cb_rtn = noteNothing, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    probe_compile = callback.vpi_register_cb(&compiled);
}

/// The message of the error the previous call recorded; "" for none.
fn lastMessage() []const u8 {
    var info: ErrorInfo = undefined;
    if (vpi_chk_error(&info) == 0) return "";
    return std.mem.span(info.message);
}

/// The port of instance `inst` named `name`, or null.
fn portNamed(inst: vpiHandle, name: []const u8) vpiHandle {
    const itr = vpi_iterate(vpiPort, inst);
    var found: vpiHandle = null;
    while (vpi_scan(itr)) |p| {
        if (found == null and std.mem.eql(u8, std.mem.span(vpi_get_str(vpiName, p)), name)) found = p;
    }
    return found;
}

fn noCb(_: *abi.CbData) callconv(.c) c_int {
    return 0;
}

/// True for a decl name spelled as a vpi_user.h constant: `vpi*`, `cb*` or
/// VerA's `acb*`, with no underscore (that is `vpi_get` and the routines).
fn isHeaderSpelling(comptime name: []const u8) bool {
    const prefixed = std.mem.startsWith(u8, name, "vpi") or std.mem.startsWith(u8, name, "cb") or
        std.mem.startsWith(u8, name, "acb");
    return prefixed and std.mem.findScalar(u8, name, '_') == null;
}

fn scaled(v: f64) Time {
    return .{ .type = user.vpiScaledRealTime, .high = 0, .low = 0, .real = v };
}

fn ticks(n: u32) Time {
    return .{ .type = user.vpiSimTime, .high = 0, .low = n, .real = 0 };
}

fn delayOf(da: []Time, n: c_int, time_type: c_int) abi.Delay {
    return .{ .da = da.ptr, .no_of_delays = n, .time_type = time_type, .mtm_flag = 0, .append_flag = 0, .pulsere_flag = 0 };
}

/// The `n`th object (from 0) `vpi_iterate(tag, scope)` yields.
fn nth(tag: c_int, scope: abi.vpiHandle, n: usize) ?*anyopaque {
    const itr = iterate.vpi_iterate(tag, scope);
    defer _ = trust.vpi_free_object(itr);
    for (0..n) |_| _ = iterate.vpi_scan(itr);
    return iterate.vpi_scan(itr);
}

/// The `vpiFullName` of `obj`'s `rel` (vpiLowConn, vpiHighConn), or "".
fn connName(rel: c_int, obj: ?*anyopaque) []const u8 {
    const h = handle.vpi_handle(rel, @ptrCast(obj)) orelse return "";
    return std.mem.span(property.vpi_get_str(user.vpiFullName, h));
}

test "the scope tree is the instance tree, with definition names" {
    var res = try openSource(nested_src);
    defer res.deinit(std.testing.allocator);
    defer close();

    const d = &session.design.?;
    try std.testing.expectEqual(@as(usize, 3), d.scopes.len);
    try std.testing.expectEqualStrings("top", d.objects[0].full);
    try std.testing.expectEqualStrings("top.u", d.objects[1].full);
    try std.testing.expectEqualStrings("top.u.v", d.objects[2].full);
    // §11.6.1 vpiDefName — the fact flattening erases.
    try std.testing.expectEqualStrings("top", d.scopes[0].def_name);
    try std.testing.expectEqualStrings("sub", d.scopes[1].def_name);
    try std.testing.expectEqualStrings("leaf", d.scopes[2].def_name);
}

test "each scope holds the declarations of its own level" {
    var res = try openSource(nested_src);
    defer res.deinit(std.testing.allocator);
    defer close();

    const d = &session.design.?;
    // §11.6.4: ports come from the definition, so a child instance has them
    // even though the flatten collapsed them into the parent's nets.
    try std.testing.expectEqual(@as(usize, 2), d.scopes[0].ports.len);
    try std.testing.expectEqual(@as(usize, 2), d.scopes[1].ports.len);
    try std.testing.expectEqualStrings("top.u.v.x", d.obj(d.scopes[2].ports[0]).*.full);
    // §11.6.8/§11.6.9/§11.6.12: one each per level, bucketed by §6.7 path.
    try std.testing.expectEqualStrings("top.mid", d.obj(d.scopes[0].nets[0]).*.full);
    try std.testing.expectEqualStrings("top.u.inner", d.obj(d.scopes[1].nets[0]).*.full);
    try std.testing.expectEqualStrings("top.u.v.deep", d.obj(d.scopes[2].nets[0]).*.full);
    try std.testing.expectEqualStrings("top.state", d.obj(d.scopes[0].regs[0]).*.full);
    try std.testing.expectEqualStrings("top.u.flag", d.obj(d.scopes[1].regs[0]).*.full);
    try std.testing.expectEqualStrings("top.u.v.r", d.obj(d.scopes[2].params[0]).*.full);
}

test "vpi_iterate walks a level and vpi_scan frees the iterator at the end" {
    var res = try openSource(nested_src);
    defer res.deinit(std.testing.allocator);
    defer close();

    const top = vpi_handle_by_name("top", null);
    try std.testing.expect(top != null);
    const itr = vpi_iterate(vpiNet, top);
    try std.testing.expect(itr != null);
    try std.testing.expectEqual(vpiIterator, vpi_get(vpiType, itr));
    const first = vpi_scan(itr);
    try std.testing.expectEqualStrings("mid", std.mem.span(vpi_get_str(vpiName, first)));
    try std.testing.expect(vpi_scan(itr) == null);
    // §12.4/§12.35: exhaustion freed it, so the handle is now invalid rather
    // than merely spent.
    try std.testing.expect(vpi_scan(itr) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "an abandoned iterator is freed by vpi_free_object" {
    var res = try openSource(nested_src);
    defer res.deinit(std.testing.allocator);
    defer close();

    const top = vpi_handle_by_name("top", null);
    const itr = vpi_iterate(vpiParameter, top);
    _ = vpi_scan(itr);
    try std.testing.expectEqual(@as(usize, 1), session.design.?.iters.count());
    try std.testing.expectEqual(@as(c_int, 1), vpi_free_object(itr));
    try std.testing.expectEqual(@as(usize, 0), session.design.?.iters.count());
}

test "§12.23: an empty handle set is NULL with no error; an iterator has its type, its iterated type and nothing else" {
    var res = try openSource(nested_src);
    defer res.deinit(std.testing.allocator);
    defer close();

    // No callback is registered and no systf: NULL, and no error (§12.23).
    try std.testing.expect(vpi_iterate(user.vpiCallback, null) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    const itr = vpi_iterate(vpiNet, vpi_handle_by_name("top", null));
    defer _ = vpi_free_object(itr);
    try std.testing.expectEqual(vpiIterator, vpi_get(vpiType, itr));
    try std.testing.expectEqual(vpiNet, vpi_get(user.vpiIteratorType, itr));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(user.vpiProtected, itr));
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiSize, itr));
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    // A property of no object, scheduled-event or iterator alike.
    try std.testing.expectEqual(vpiUndefined, vpi_get(user.vpiScheduled, itr));
}

test "the §6.7 upward scope search, and absolute names" {
    var res = try openSource(nested_src);
    defer res.deinit(std.testing.allocator);
    defer close();

    const leaf = vpi_handle_by_name("top.u.v", null);
    try std.testing.expect(leaf != null);
    // Its own declaration.
    try std.testing.expect(vpi_handle_by_name("deep", leaf) != null);
    // One its grandparent declares — found by walking up.
    const mid = vpi_handle_by_name("mid", leaf);
    try std.testing.expect(mid != null);
    try std.testing.expectEqualStrings("top.mid", std.mem.span(vpi_get_str(vpiFullName, mid)));
    // §12.3: two handles to one object are the same object.
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(mid, vpi_handle_by_name("top.mid", null)));
    try std.testing.expectEqual(@as(c_int, 0), vpi_compare_objects(mid, leaf));
    // §11.6.4's edge back to the module, from both tags.
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(
        vpi_handle(vpiScope, mid),
        vpi_handle(vpiModule, mid),
    ));
}

test "an invalid handle is an error, not a crash" {
    var res = try openSource(nested_src);
    defer res.deinit(std.testing.allocator);
    defer close();

    // A pointer into the object array but off an element boundary, and one past
    // its end: the two shapes a stale or corrupted handle takes.
    const base = @intFromPtr(session.design.?.objects.ptr);
    const misaligned: vpiHandle = @ptrFromInt(base + 1);
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiType, misaligned));
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    const past: vpiHandle = @ptrFromInt(base + session.design.?.objects.len * @sizeOf(Obj));
    try std.testing.expect(vpi_get_str(vpiName, past) == null);
    try std.testing.expect(vpi_iterate(vpiNet, past) == null);
    try std.testing.expect(vpi_handle(vpiScope, past) == null);
    try std.testing.expect(vpi_handle_by_index(past, 0) == null);
    try std.testing.expect(vpi_handle_by_name("mid", past) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_free_object(past));
    // NULL is a handle too, and §12.5's NULL case is not one VerA answers.
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiType, null));
}

test "unsupported property requests report vpiError and vpiUndefined" {
    var res = try openSource(nested_src);
    defer res.deinit(std.testing.allocator);
    defer close();

    const top = vpi_handle_by_name("top", null);
    const net = vpi_handle_by_name("top.mid", null);
    // §11.6.8 gives a net no direction and §11.6.1 gives a module no size.
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiDirection, net));
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiSize, top));
    try std.testing.expect(vpi_get_str(vpiDefName, net) == null);
    // A property VerA does not answer at all (vpiFile, §11.6.1's location).
    try std.testing.expectEqual(vpiUndefined, vpi_get(5, top));
    // And a successful call clears the status again (§12.2).
    try std.testing.expectEqual(vpiModule, vpi_get(vpiType, top));
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
}

test "§11.6.5–§11.6.7: nodes, a branch between them, and its two quantities" {
    var res = try openSource(
        \\module br(p, n);
        \\  inout p, n; electrical p, n;
        \\  electrical mid;
        \\  branch (p, mid) b;
        \\  analog I(b) <+ V(b);
        \\endmodule
    );
    defer res.deinit(std.testing.allocator);
    defer close();

    const top = vpi_handle_by_name("br", null);
    const mid = vpi_handle(vpiNode, vpi_handle_by_name("br.mid", null));
    try std.testing.expectEqual(vpiNode, vpi_get(vpiType, mid));
    const b = vpi_handle_by_name("br.b", null);
    try std.testing.expectEqual(vpiBranch, vpi_get(vpiType, b));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiNegNode, b), mid));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(
        vpi_handle(vpiPosNode, b),
        vpi_handle(vpiNode, vpi_handle_by_name("br.p", null)),
    ));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiModule, b), top));
    const q = vpi_handle(vpiFlow, b);
    try std.testing.expectEqual(vpiQuantity, vpi_get(vpiType, q));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiBranch, q), b));
    // Annex D's electrical: flow nature Current, potential nature Voltage.
    try std.testing.expectEqualStrings("Current", std.mem.span(vpi_get_str(vpiName, vpi_handle(vpiNature, q))));
    try std.testing.expectEqualStrings("Voltage", std.mem.span(vpi_get_str(vpiName, vpi_handle(vpiNature, vpi_handle(vpiPotential, b)))));
    try std.testing.expectEqualStrings("electrical", std.mem.span(vpi_get_str(vpiName, vpi_handle(vpiDiscipline, b))));
    // A quantity has no name, and a node draws no branch edge.
    try std.testing.expect(vpi_get_str(vpiName, q) == null);
    try std.testing.expect(vpi_handle(vpiPosNode, mid) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "§5.4.2/§11.6.6: an instance's `<+` declares an unnamed branch the instance iterates" {
    var res = try openSource(
        \\`include "disciplines.vams"
        \\module vsrc(p, n); inout p, n; electrical p, n;
        \\  analog V(p, n) <+ 1.25;
        \\endmodule
        \\module res(p, n); inout p, n; electrical p, n;
        \\  analog I(p, n) <+ V(p, n) / 500.0;
        \\endmodule
        \\module top; electrical a, gnd; ground gnd;
        \\  vsrc v1(.p(a), .n(gnd));
        \\  res r1(.p(a), .n(gnd));
        \\  res r2(.p(a), .n(gnd));
        \\endmodule
    );
    defer res.deinit(std.testing.allocator);
    defer close();
    // One unnamed branch per instance, each in ITS scope, though all three
    // span the same pair (a, gnd).
    for ([_][]const u8{ "top.v1", "top.r1", "top.r2" }) |inst| {
        const it = vpi_iterate(vpiBranch, vpi_handle_by_name(@constCast(inst.ptr), null));
        try std.testing.expect(it != null);
        const b = vpi_scan(it).?;
        try std.testing.expect(vpi_scan(it) == null);
        const o = schema.coldOf(asObj(b).?);
        try std.testing.expect(o.pos != .none);
        try std.testing.expect(o.neg == .none); // gnd is §1.3.1.1's reference
        try std.testing.expectEqual(vpiQuantity, vpi_get(vpiType, vpi_handle(vpiFlow, b)));
    }
    const v1 = schema.coldOf(asObj(vpi_scan(vpi_iterate(vpiBranch, vpi_handle_by_name(@constCast("top.v1"), null))).?).?);
    try std.testing.expect(v1.contrib_pot != null and v1.contrib_flow == null);
    // r1 and r2 are two devices in parallel: lowering sums their `<+` into
    // one row, and each branch's flow is its own instance's share of it
    // (`Lowered.contrib_shares`), not the total.
    const r1 = schema.coldOf(asObj(vpi_scan(vpi_iterate(vpiBranch, vpi_handle_by_name(@constCast("top.r1"), null))).?).?);
    const r2 = schema.coldOf(asObj(vpi_scan(vpi_iterate(vpiBranch, vpi_handle_by_name(@constCast("top.r2"), null))).?).?);
    try std.testing.expect(r1.contrib_flow != null and !r1.flow_unknowable);
    try std.testing.expectEqual(r1.contrib_flow, r2.contrib_flow);
    try std.testing.expect(r1.contrib_share != null and r2.contrib_share != null);
    try std.testing.expect(r1.contrib_share.? != r2.contrib_share.?);
}

test "§5.6.8.2: a named branch another instance contributes to reads its own row" {
    var res = try openSource(
        \\`include "disciplines.vams"
        \\module child(b); inout b; electrical b, x;
        \\  branch (x, b) br;
        \\  analog I(br) <+ V(br) / 1000.0;
        \\endmodule
        \\module top(g); inout g; electrical g;
        \\  child drv(g);
        \\  analog I(drv.br) <+ 1m;
        \\endmodule
    );
    defer res.deinit(std.testing.allocator);
    defer close();
    // The parent's `<+` lands on the child's own branch: one row, `shared`,
    // and all of it is that branch's flow, so there is no share to look up.
    const br = schema.coldOf(asObj(vpi_scan(vpi_iterate(vpiBranch, vpi_handle_by_name(@constCast("top.drv"), null))).?).?);
    try std.testing.expect(br.contrib_flow != null and br.contrib_share == null and !br.flow_unknowable);
}

test "§11.6.20/§11.6.21: the analog process, its contribution and an identifier that IS its object" {
    var res = try openSource(
        \\module ct(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real g = 2.0;
        \\  branch (p, n) b;
        \\  analog I(b) <+ g * V(b);
        \\endmodule
    );
    defer res.deinit(std.testing.allocator);
    defer close();

    const top = vpi_handle_by_name("ct", null);
    const procs = vpi_iterate(user.vpiProcess, top);
    const proc = vpi_scan(procs);
    try std.testing.expect(vpi_scan(procs) == null);
    try std.testing.expectEqual(user.vpiAnalog, vpi_get(vpiType, proc));
    const c = vpi_handle(user.vpiStmt, proc);
    try std.testing.expectEqual(user.vpiContrib, vpi_get(vpiType, c));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiFlow, c));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiBranch, c), vpi_handle_by_name("ct.b", null)));
    const rhs = vpi_handle(user.vpiRhs, c);
    try std.testing.expectEqual(user.vpiMultOp, vpi_get(user.vpiOpType, rhs));
    // §11.6.18: the operand `g` is the parameter object itself.
    const ops = vpi_iterate(user.vpiOperand, rhs);
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_scan(ops), vpi_handle_by_name("ct.g", null)));
    try std.testing.expectEqual(user.vpiAccessFunc, vpi_get(vpiType, vpi_scan(ops)));
    try std.testing.expect(vpi_scan(ops) == null);
}

test "a single-module design is a tree of one" {
    var res = try openSource(
        \\module only(p);
        \\  inout p; electrical p;
        \\  parameter real w = 1.0;
        \\  analog I(p) <+ w*V(p);
        \\endmodule
    );
    defer res.deinit(std.testing.allocator);
    defer close();

    const top = vpi_handle_by_name("only", null);
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiTopModule, top));
    try std.testing.expect(vpi_handle(vpiScope, top) == null);
    // §12.23: an empty set is NULL with NO error.
    try std.testing.expect(vpi_iterate(vpiReg, top) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    // §11.6.1 NOTE 1, and there is exactly one root.
    const roots = vpi_iterate(vpiModule, null);
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(top, vpi_scan(roots)));
    try std.testing.expect(vpi_scan(roots) == null);
}

test "port, reg and parameter properties come from the declaration" {
    var res = try openSource(nested_src);
    defer res.deinit(std.testing.allocator);
    defer close();

    const p = vpi_handle_by_name("top.p", null);
    try std.testing.expectEqual(vpiInout, vpi_get(vpiDirection, p));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiPortIndex, p));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiScalar, p));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiPortIndex, vpi_handle_by_name("top.n", null)));
    // §11.6.9 — a packed reg is a vector of its declared width.
    const state = vpi_handle_by_name("top.state", null);
    try std.testing.expectEqual(@as(c_int, 4), vpi_get(vpiSize, state));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiVector, state));
    // §3.4.5 as the SOURCE wrote it, not as the flatten rewrote it: `u.k` is a
    // child's `parameter`, which elaboration turned into a `localparam`.
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiLocalParam, vpi_handle_by_name("top.g", null)));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiLocalParam, vpi_handle_by_name("top.tag", null)));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiLocalParam, vpi_handle_by_name("top.u.k", null)));
    try std.testing.expectEqual(vpiRealConst, vpi_get(vpiConstType, vpi_handle_by_name("top.u.k", null)));
    try std.testing.expectEqual(vpiIntConst, vpi_get(vpiConstType, vpi_handle_by_name("top.tag", null)));
}

test "a vector net reports its folded §3.6.3 width" {
    var res = try openSource(
        \\module vec(p);
        \\  inout p; electrical p;
        \\  electrical [0:3] bus;
        \\  analog I(p) <+ V(p);
        \\endmodule
    );
    defer res.deinit(std.testing.allocator);
    defer close();

    const bus = vpi_handle_by_name("vec.bus", null);
    try std.testing.expectEqual(@as(c_int, 4), vpi_get(vpiSize, bus));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiScalar, bus));
}

test "vpi_handle_by_index reports the unsupported class rather than guessing" {
    var res = try openSource(nested_src);
    defer res.deinit(std.testing.allocator);
    defer close();

    const state = vpi_handle_by_name("top.state", null);
    try std.testing.expect(vpi_handle_by_index(state, 0) == null);
    var info: ErrorInfo = undefined;
    try std.testing.expectEqual(vpiError, vpi_chk_error(&info));
    try std.testing.expectEqual(vpiPLI, info.state);
    try std.testing.expectEqualStrings("NOINDEX", std.mem.span(info.code));
    try std.testing.expectEqualStrings("VerA", std.mem.span(info.product));
    // §12.2: vpi_chk_error itself does not reset the status.
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "handles survive the compilation they were built from" {
    // `Design` copies every string it reports, so freeing the Result
    // leaves the handles valid.
    var res = try openSource(nested_src);
    defer close();
    const leaf = vpi_handle_by_name("top.u.v", null);
    res.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("leaf", std.mem.span(vpi_get_str(vpiDefName, leaf)));
    try std.testing.expectEqualStrings("top.u.v.deep", std.mem.span(
        vpi_get_str(vpiFullName, vpi_handle_by_name("deep", leaf)),
    ));
}

test "§12.33.2 runs every entry of the table, in order, and stops at the 0" {
    startup_calls = 0;
    // A null table is a no-op: an application that registers nothing at startup
    // is a legal application.
    runStartupTable(null);
    try std.testing.expectEqual(@as(usize, 0), startup_calls);
    // "0 shall be last entry in list" — and an entry AFTER it is not reached,
    // which is what makes the terminator the terminator.
    const table = [_]?StartupFn{ &countStartupCall, &countStartupCall, null, &countStartupCall };
    runStartupTable(&table);
    try std.testing.expectEqual(@as(usize, 2), startup_calls);
}

test "no design open is an error on every routine" {
    close();
    try std.testing.expect(vpi_handle_by_name("top", null) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expect(vpi_iterate(vpiModule, null) == null);
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiType, null));
    try std.testing.expect(vpi_get_str(vpiName, null) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_compare_objects(null, null));
    try std.testing.expectEqual(@as(c_int, 0), vpi_release_handle(null));
}

// ---- the scope tree is elaboration's, read and not re-derived --------------

test "an instance array is one scope per element (§6.2.2, §6.7)" {
    // §6.2.2 `name_of_module_instance ::= module_instance_identifier [ range ]`,
    // and §6.7 addresses each element as `u[1].inner`. Elaboration inlines one
    // unit per element, so the VPI has one module per element.
    var res = try openSource(
        \\module top(p, n);
        \\  inout p, n; electrical p, n;
        \\  sub u[1:0](p, n);
        \\endmodule
        \\module sub(a, b);
        \\  inout a, b; electrical a, b;
        \\  electrical inner;
        \\  analog I(a,b) <+ V(a,b);
        \\endmodule
    );
    defer res.deinit(std.testing.allocator);
    defer close();

    try std.testing.expectEqual(@as(usize, 3), session.design.?.scopes.len);
    try std.testing.expectEqualStrings("sub", (try scopeAt("u[0]")).def_name);
    try std.testing.expectEqualStrings("sub", (try scopeAt("u[1]")).def_name);
    const net = vpi_handle_by_name("top.u[1].inner", null);
    try std.testing.expect(net != null);
    try std.testing.expectEqual(vpiNet, vpi_get(vpiType, net));
    try std.testing.expect(vpi_handle_by_name("top.u[0].a", null) != null);
}

test "a paramset instance is an instance of the module §6.4.2 selected, through the chain" {
    // §6.4 "A chain of paramsets may be defined, but the last paramset in the
    // chain shall reference a module": `c` names `outer`, which names `mid`,
    // which names `leaf`. §6.4.2 selects between the two `pick`s by the range
    // that admits "PMOS", so `s` is a `pmod` and not the first `pick`'s `nmod`.
    // §12.12's example reads that module back as `vpiDefName`.
    var res = try openSource(
        \\module top(p, n);
        \\  inout p, n; electrical p, n;
        \\  outer c(p, n);
        \\  pick #(.t("PMOS")) s(p, n);
        \\endmodule
        \\paramset outer mid;
        \\  real tag;
        \\  tag = 1.0;
        \\endparamset
        \\paramset mid leaf;
        \\  parameter real unused_item = 0; // A.1.9: one item declaration at least
        \\  .j = 2.0;
        \\endparamset
        \\paramset pick nmod;
        \\  parameter string t = "NMOS" from '{ "NMOS" };
        \\  .sign = 1.0;
        \\endparamset
        \\paramset pick pmod;
        \\  parameter string t = "PMOS" from '{ "PMOS" };
        \\  .sign = -1.0;
        \\endparamset
        \\module leaf(a, b);
        \\  inout a, b; electrical a, b;
        \\  parameter real j = 0.0;
        \\  analog I(a,b) <+ j*V(a,b);
        \\endmodule
        \\module nmod(a, b);
        \\  inout a, b; electrical a, b;
        \\  parameter real sign = 0.0;
        \\  analog I(a,b) <+ sign*V(a,b);
        \\endmodule
        \\module pmod(a, b);
        \\  inout a, b; electrical a, b;
        \\  parameter real sign = 0.0;
        \\  analog I(a,b) <+ sign*V(a,b);
        \\endmodule
    );
    defer res.deinit(std.testing.allocator);
    defer close();

    try std.testing.expectEqualStrings("leaf", (try scopeAt("c")).def_name);
    try std.testing.expectEqualStrings("pmod", (try scopeAt("s")).def_name);
    try std.testing.expect(vpi_handle_by_name("top.c.j", null) != null);
}

test "an instance resolved by Annex E.2.1's case-insensitive netlist match has its scope" {
    // E.2.1 "if no exact match is found, the mixed-case name shall match the
    // same name defined within SPICE regardless of the case". That rule is
    // about which MODULE an instance names, and elaboration owns it.
    //
    // It is NOT a rule about `vpi_handle_by_name`: §12.21 searches "using the
    // scope search rules defined by the Verilog-AMS HDL", and §2.7 makes those
    // case-sensitive. So `TOP.Q` still finds nothing.
    var res = try vera.analyze(std.testing.allocator,
        \\module top(c, b, e);
        \\  inout c, b, e; electrical c, b, e;
        \\  VeRtNpN q(c, b, e);
        \\endmodule
    , .{ .spice_netlist = ".MODEL VERTNPN NPN BF=80 IS=1E-18\n" }, null);
    defer res.deinit(std.testing.allocator);
    try open(std.testing.allocator, &res);
    defer close();

    const q = try scopeAt("q");
    try std.testing.expect(std.ascii.eqlIgnoreCase("vertnpn", q.def_name));
    // The card synthesizes `module vertnpn(c, b, e, s)`: its ports are
    // the definition's, so the scope has all four.
    try std.testing.expectEqual(@as(usize, 4), q.ports.len);
    try std.testing.expect(vpi_handle_by_name("top.q", null) != null);
    try std.testing.expect(vpi_handle_by_name("TOP.Q", null) == null);
}

test "the scopes are elaboration's units, one for one" {
    // One owner per fact: `elab.Design.units` is the instance tree the
    // flatten built. Every unit is a scope with its path and module, in the
    // same depth-first source order, and there is no other scope.
    var res = try openSource(
        \\module top(p, n);
        \\  inout p, n; electrical p, n;
        \\  sub u[0:1](p, n);
        \\  ps w(p, n);
        \\endmodule
        \\paramset ps sub;
        \\  parameter real unused_item = 0; // A.1.9: one item declaration at least
        \\  .k = 2.0;
        \\endparamset
        \\module sub(a, b);
        \\  inout a, b; electrical a, b;
        \\  parameter real k = 1.0;
        \\  leaf v(a, b);
        \\endmodule
        \\module leaf(x, y);
        \\  inout x, y; electrical x, y;
        \\  analog I(x,y) <+ V(x,y);
        \\endmodule
    );
    defer res.deinit(std.testing.allocator);
    defer close();

    const units = res.unit_paths;
    try std.testing.expectEqual(@as(usize, 7), units.len);
    try std.testing.expectEqual(units.len, session.design.?.scopes.len);
    for (units.items(.module), units.items(.path), session.design.?.scopes) |module, path, s| {
        try std.testing.expectEqualStrings(res.file.str(module), s.def_name);
        try std.testing.expectEqualStrings(std.mem.trimEnd(u8, path, &.{elab.sep}), s.path);
    }
}

// ---- §11.6.10/§11.6.11 arrays and §6.2.2 instance arrays --------------------

test "an instance array is a vpiModuleArray over its members (§6.2.2, IEEE 1364 §26.6.1)" {
    var res = try openSource(
        \\module top(p, n);
        \\  inout p, n; electrical p, n;
        \\  sub u[1:0](p, n);
        \\endmodule
        \\module sub(a, b);
        \\  inout a, b; electrical a, b;
        \\  analog I(a,b) <+ V(a,b);
        \\endmodule
    );
    defer res.deinit(std.testing.allocator);
    defer close();

    const top = vpi_handle_by_name("top", null);
    // A module in no array has no index, and that is not an error.
    try std.testing.expect(vpi_handle(vpiIndex, top) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiArray, top));

    const u = vpi_handle_by_name("top.u", null);
    try std.testing.expectEqual(vpiModuleArray, vpi_get(vpiType, u));
    try std.testing.expectEqual(@as(c_int, 2), vpi_get(vpiSize, u));
    const itr = vpi_iterate(vpiModule, u);
    var seen: u32 = 0;
    while (vpi_scan(itr)) |m| {
        try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiArray, m));
        try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiModuleArray, m), u));
        var v: abi.Value = std.mem.zeroes(abi.Value);
        v.format = user.vpiIntVal;
        const index = vpi_handle(vpiIndex, m);
        try std.testing.expectEqual(vpiConstant, vpi_get(vpiType, index));
        value.vpi_get_value(index, &v);
        try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
        seen |= @as(u32, 1) << @intCast(v.value.integer);
        try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle_by_index(u, v.value.integer), m));
    }
    try std.testing.expectEqual(@as(u32, 3), seen);
    try std.testing.expect(vpi_handle_by_index(u, 2) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    // Iterating a module's instance arrays.
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_scan(vpi_iterate(vpiModuleArray, top)), u));
}

test "a digital memory is a vpiRegArray of vpiReg words, each bound to its engine slot" {
    var h: run.Harness = undefined;
    try h.init(
        \\module m;
        \\  reg [7:0] mem [0:3];
        \\  integer counts [2:1];
        \\  real samples [1:0];
        \\  initial begin mem[2] = 8'h7e; counts[1] = 5; end
        \\endmodule
    );
    defer h.deinit();
    try run.simulate();

    const top = vpi_handle_by_name("m", null);
    const mem = vpi_scan(vpi_iterate(vpiMemory, top));
    try std.testing.expectEqual(vpiRegArray, vpi_get(vpiType, mem));
    try std.testing.expectEqualStrings("vpiRegArray", std.mem.span(vpi_get_str(vpiType, mem)));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiIsMemory, mem));
    try std.testing.expectEqual(@as(c_int, 4), vpi_get(vpiSize, mem));
    const w2 = vpi_handle_by_index(mem, 2);
    try std.testing.expectEqual(vpiReg, vpi_get(vpiType, w2));
    try std.testing.expectEqual(@as(c_int, 8), vpi_get(vpiSize, w2));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiParent, w2), mem));
    try std.testing.expectEqualStrings("m.mem[2]", std.mem.span(vpi_get_str(vpiFullName, w2)));
    var v: abi.Value = std.mem.zeroes(abi.Value);
    v.format = user.vpiIntVal;
    value.vpi_get_value(w2, &v);
    try std.testing.expectEqual(@as(c_int, 0x7e), v.value.integer);
    // Every word, by the legacy tag.
    var words: u32 = 0;
    const itr = vpi_iterate(vpiMemoryWord, mem);
    while (vpi_scan(itr)) |_| words += 1;
    try std.testing.expectEqual(@as(u32, 4), words);

    // An integer array is an integer variable with vpiArray set, whose
    // elements are variable selects.
    const counts = vpi_handle_by_name("m.counts", null);
    try std.testing.expectEqual(vpiIntegerVar, vpi_get(vpiType, counts));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiArray, counts));
    const c1 = vpi_scan(vpi_iterate(vpiVarSelect, counts));
    try std.testing.expectEqual(vpiVarSelect, vpi_get(vpiType, c1));
    value.vpi_get_value(c1, &v);
    try std.testing.expectEqual(@as(c_int, 5), v.value.integer);

    // A real array is a real variable with vpiArray set (§26.6.7).
    const samples = vpi_handle_by_name("m.samples", null);
    try std.testing.expectEqual(vpiRealVar, vpi_get(vpiType, samples));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiArray, samples));
    try std.testing.expectEqual(@as(c_int, 2), vpi_get(vpiSize, samples));
}

test "a digital scope is the engine's instance, past a task frame and a loop generate (§11.2.2)" {
    var h: run.Harness = undefined;
    try h.init(
        \\module leaf #(parameter V = 0); reg [7:0] r; initial r = V; endmodule
        \\module top;
        \\  task t; begin end endtask
        \\  genvar i;
        \\  generate for (i = 0; i < 2; i = i + 1) begin : g
        \\    leaf #(i + 1) u();
        \\  end endgenerate
        \\  leaf #(8'h11) c();
        \\  initial t;
        \\endmodule
    );
    defer h.deinit();
    try run.simulate();

    var v: abi.Value = std.mem.zeroes(abi.Value);
    v.format = user.vpiIntVal;
    for ([_]struct { []const u8, c_int }{ .{ "top.c.r", 0x11 }, .{ "top.g[0].u.r", 1 }, .{ "top.g[1].u.r", 2 } }) |want| {
        const name = try std.testing.allocator.dupeSentinel(u8, want[0], 0);
        defer std.testing.allocator.free(name);
        const r = vpi_handle_by_name(name, null) orelse return error.TestUnexpectedResult;
        value.vpi_get_value(r, &v);
        try std.testing.expectEqual(want[1], v.value.integer);
    }
    const g0 = vpi_handle_by_name("top.g[0].u", null);
    try std.testing.expectEqualStrings("leaf", std.mem.span(vpi_get_str(vpiDefName, g0)));
    // The generate iterations are path components, not scopes: all three
    // instances are children of `top`.
    var children: u32 = 0;
    const itr = vpi_iterate(vpiModule, vpi_handle_by_name("top", null));
    while (vpi_scan(itr)) |_| children += 1;
    try std.testing.expectEqual(@as(u32, 3), children);
}

test "IEEE 1364-2005 §13.6: vpiLibrary, vpiCell and vpiConfig of a configured module" {
    var h: run.Harness = undefined;
    try h.init(
        \\config cfg; design work.top; instance top.u use gate; endconfig
        \\module rtl; endmodule
        \\module gate; endmodule
        \\module top; rtl u(); endmodule
    );
    defer h.deinit();
    try run.simulate();
    const u = vpi_handle_by_name("top.u", null);
    try std.testing.expectEqualStrings("work", std.mem.span(vpi_get_str(vpiLibrary, u)));
    try std.testing.expectEqualStrings("gate", std.mem.span(vpi_get_str(vpiCell, u)));
    try std.testing.expectEqualStrings("work.cfg", std.mem.span(vpi_get_str(vpiConfig, u)));
}

test "an analog real array and real variable are §11.6.10's classes" {
    var res = try openSource(
        \\module ra(p);
        \\  inout p; electrical p;
        \\  real samples[1:0];
        \\  real x;
        \\  analog begin
        \\    samples[0] = V(p); samples[1] = 2*V(p); x = samples[0];
        \\    I(p) <+ x;
        \\  end
        \\endmodule
    );
    defer res.deinit(std.testing.allocator);
    defer close();
    const arr = vpi_handle_by_name("ra.samples", null);
    try std.testing.expectEqual(vpiRealVar, vpi_get(vpiType, arr));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiArray, arr));
    try std.testing.expectEqual(@as(c_int, 2), vpi_get(vpiSize, arr));
    const sel = vpi_handle_by_index(arr, 1);
    try std.testing.expectEqual(vpiVarSelect, vpi_get(vpiType, sel));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiParent, sel), arr));
    const x = vpi_handle_by_name("ra.x", null);
    try std.testing.expectEqual(vpiRealVar, vpi_get(vpiType, x));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiArray, x));
}

test "IEEE 1364-2005 §26.6.22/§26.6.23: drivers and loads of nets and regs" {
    var h: run.Harness = undefined;
    try h.init(
        \\module m(i, o);
        \\  input i;
        \\  output o;
        \\  wire w;
        \\  reg r;
        \\  assign w = r & i;
        \\  not (o, w);
        \\endmodule
    );
    defer h.deinit();
    const top = vpi_handle_by_name("m", null);
    // `i` and `o` are implicit nets (§12.3.3); by name they are the ports.
    var nets: [4]vpiHandle = undefined;
    var n: usize = 0;
    const itr = vpi_iterate(vpiNet, top);
    while (vpi_scan(itr)) |x| : (n += 1) nets[n] = x;
    try std.testing.expectEqual(@as(usize, 3), n);
    const Want = struct { name: []const u8, implicit: bool = false, drivers: []const c_int, loads: []const c_int };
    // Each set as its members' types, in object order.
    for ([_]Want{
        .{ .name = "w", .drivers = &.{user.vpiContAssign}, .loads = &.{user.vpiPrimTerm} },
        .{ .name = "i", .implicit = true, .drivers = &.{vpiPort}, .loads = &.{user.vpiContAssign} },
        .{ .name = "o", .implicit = true, .drivers = &.{user.vpiPrimTerm}, .loads = &.{vpiPort} },
        .{ .name = "r", .drivers = &.{}, .loads = &.{user.vpiContAssign} },
    }) |want| {
        const obj = for (nets[0..n]) |x| {
            if (std.mem.eql(u8, std.mem.span(vpi_get_str(vpiName, x)), want.name)) break x;
        } else vpi_handle_by_name("m.r", null);
        if (vpi_get(vpiType, obj) == vpiNet) try std.testing.expectEqual(@as(c_int, @intFromBool(want.implicit)), vpi_get(user.vpiImplicitDecl, obj));
        for ([_]c_int{ user.vpiDriver, user.vpiLoad }, [_][]const c_int{ want.drivers, want.loads }) |tag, types| {
            var got: [4]c_int = undefined;
            var k: usize = 0;
            const it = vpi_iterate(tag, obj);
            try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
            if (it != null) while (vpi_scan(it)) |x| : (k += 1) {
                got[k] = vpi_get(vpiType, x);
            };
            try std.testing.expectEqualSlices(c_int, types, got[0..k]);
        }
    }
}

test "IEEE 1364-2005 §26.6.13 switches, pull sources and strengths; §26.6.6 l local drivers across a port" {
    var h: run.Harness = undefined;
    try h.init(
        \\module m;
        \\  wire w, z;
        \\  reg a, c;
        \\  pullup (w);
        \\  nmos (w, a, c);
        \\  and (strong0, pull1) g1 (z, a, c);
        \\  leaf u(.x(w));
        \\endmodule
        \\module leaf(x);
        \\  input x;
        \\  wire y;
        \\  buf (y, x);
        \\endmodule
    );
    defer h.deinit();
    const top = vpi_handle_by_name("m", null);
    var prims: [3]vpiHandle = undefined;
    var n: usize = 0;
    const itr = vpi_iterate(user.vpiPrimitive, top);
    while (vpi_scan(itr)) |x| : (n += 1) prims[n] = x;
    try std.testing.expectEqual(@as(usize, 3), n);
    // Gates, then pull sources, then switches.
    try std.testing.expectEqualStrings("g1", std.mem.span(vpi_get_str(vpiName, prims[0])));
    try std.testing.expectEqual(@as(c_int, 0x40), vpi_get(user.vpiStrength0, prims[0]));
    try std.testing.expectEqual(@as(c_int, 0x20), vpi_get(user.vpiStrength1, prims[0]));
    try std.testing.expectEqual(user.vpiGate, vpi_get(vpiType, prims[1]));
    try std.testing.expectEqual(user.vpiPullupPrim, vpi_get(user.vpiPrimType, prims[1]));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiSize, prims[1]));
    try std.testing.expectEqual(@as(c_int, 0x20), vpi_get(user.vpiStrength1, prims[1]));
    try std.testing.expectEqual(user.vpiSwitch, vpi_get(vpiType, prims[2]));
    try std.testing.expectEqual(@as(c_int, 13), vpi_get(user.vpiPrimType, prims[2]));
    try std.testing.expectEqual(@as(c_int, 2), vpi_get(vpiSize, prims[2]));

    const count = struct {
        fn f(tag: c_int, obj: vpiHandle) usize {
            var k: usize = 0;
            const it = vpi_iterate(tag, obj);
            if (it != null) while (vpi_scan(it)) |_| {
                k += 1;
            };
            return k;
        }
    }.f;
    const w = vpi_handle_by_name("m.w", null);
    // The pullup's and the switch's output terms; the buf in u reads w
    // through the collapsed port, a load of w but not a local one.
    try std.testing.expectEqual(@as(usize, 2), count(user.vpiLocalDriver, w));
    try std.testing.expectEqual(@as(usize, 0), count(user.vpiLocalLoad, w));
    try std.testing.expectEqual(@as(usize, 1), count(user.vpiLoad, w));
    var ux: vpiHandle = null;
    const nets = vpi_iterate(vpiNet, vpi_handle_by_name("m.u", null));
    while (vpi_scan(nets)) |x| if (std.mem.eql(u8, std.mem.span(vpi_get_str(vpiName, x)), "x")) {
        ux = x;
    };
    // Details l: an input port drives its net locally; across the port the
    // pullup and the switch drive it too.
    try std.testing.expectEqual(@as(usize, 1), count(user.vpiLocalDriver, ux));
    try std.testing.expectEqual(@as(usize, 3), count(user.vpiDriver, ux));
}

// ---- root.zig's own pieces --------------------------------------------------

test "ObjId and Slot pack null as none and round-trip every other value" {
    try std.testing.expectEqual(schema.ObjId.none, schema.ObjId.of(null));
    try std.testing.expectEqual(@as(?u32, null), schema.ObjId.none.get());
    try std.testing.expectEqual(schema.Slot.none, schema.Slot.of(null));
    try std.testing.expectEqual(@as(?u32, null), schema.Slot.none.get());
    for ([_]u32{ 0, 1, 0x7fff_ffff, std.math.maxInt(u32) - 1 }) |v| {
        try std.testing.expectEqual(@as(?u32, v), schema.ObjId.of(v).get());
        try std.testing.expectEqual(v, schema.ObjId.at(v).index());
        try std.testing.expectEqual(@as(?u32, v), schema.Slot.of(v).get());
    }
}

test "every declared class has a vpiType with a spelling" {
    for (std.enums.values(schema.Kind)) |k| {
        if (k == .code) continue;
        // A variable array's type follows its element type.
        for ([_]Ast.Type{ .integer, .real }) |ty| {
            const o: Obj = .{ .kind = k, .owner = .none, .name = "", .full = "", .ty = ty };
            try std.testing.expect(!std.mem.eql(u8, "vpiUndefined", schema.typeName(schema.typeOf(&o))));
        }
    }
}

test "§12.2: a message past the 512-byte buffer is cut short and still terminated" {
    close();
    const long: [600]u8 = @splat('m');
    status.fail("LONG", "{s}", .{&long});
    var info: ErrorInfo = undefined;
    try std.testing.expectEqual(vpiError, vpi_chk_error(&info));
    const message = std.mem.span(info.message);
    try std.testing.expectEqual(@as(usize, 511), message.len);
    try std.testing.expect(std.mem.allEqual(u8, message, 'm'));
    try std.testing.expectEqualStrings("LONG", std.mem.span(info.code));
    // The application's call site is reported absent, not invented.
    try std.testing.expect(info.file == null);
    try std.testing.expectEqual(@as(c_int, 0), info.line);
    // vpi_chk_error leaves the status as it found it.
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "IEEE 1364-2005 §26.2.4: during startup only the registrations answer" {
    close();
    defer close();
    const table = [_]?StartupFn{ &probeStartup, null };
    runStartupTable(&table);
    try std.testing.expect(probe_starting);
    try std.testing.expect(!session.starting);
    try std.testing.expectEqual(vpiUndefined, probe_get);
    try std.testing.expect(probe_refused);
    // A time callback waits for the run; an end-of-compile one is legal now.
    try std.testing.expect(probe_timed == null);
    try std.testing.expect(probe_compile != null);
}

test "§12.17 vpi_get_vlog_info: the host's invocation and the product" {
    var argv0 = "vera".*;
    var argv = [_][*c]u8{&argv0};
    session.setInvocation(1, &argv);
    defer session.setInvocation(0, null);
    var info: abi.VlogInfo = undefined;
    try std.testing.expectEqual(@as(c_int, 1), session.vpi_get_vlog_info(&info));
    try std.testing.expectEqual(@as(c_int, 1), info.argc);
    try std.testing.expectEqualStrings("vera", std.mem.span(info.argv[0]));
    try std.testing.expectEqualStrings("VerA", std.mem.span(info.product));
    try std.testing.expectEqual(@as(c_int, 0), session.vpi_get_vlog_info(null));
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "a pointer one row below the object array is no handle" {
    var res = try openSource(nested_src);
    defer res.deinit(std.testing.allocator);
    defer close();
    const base = @intFromPtr(session.design.?.objects.ptr);
    try std.testing.expect(asObj(@ptrFromInt(base - @sizeOf(Obj))) == null);
    try std.testing.expect(trust.issued(@ptrFromInt(base - @sizeOf(Obj))) == null);
    const first = asObj(@ptrFromInt(base)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(first == &session.design.?.objects[0]);
}

test "§12.19-§12.21, IEEE 1364-2005 §27.18 and §26.6.43: the lookup routines' refusals" {
    var res = try openSource(nested_src);
    defer res.deinit(std.testing.allocator);
    defer close();
    const top = vpi_handle_by_name("top", null);
    // §12.21: a NULL name; a name absent from the design and from a scope.
    try std.testing.expect(vpi_handle_by_name(null, null) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expect(vpi_handle_by_name("top.nothing", null) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expect(vpi_handle_by_name("nothing", top) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    // §27.18: a NULL index array, and two indices on a class that takes one.
    const indices = [_]c_int{ 0, 1 };
    try std.testing.expect(handle.vpi_handle_by_multi_index(top, 1, null) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expect(handle.vpi_handle_by_multi_index(top, 2, &indices) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    // §26.6.43: an iterator's one edge is vpiUse, the reference it was made
    // from; any other is no relationship.
    const itr = vpi_iterate(vpiNet, top);
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(user.vpiUse, itr), top));
    try std.testing.expect(vpi_handle(vpiScope, itr) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 1), vpi_free_object(itr));
    // A relationship a net's diagram does not draw.
    try std.testing.expect(vpi_handle(vpiPosNode, vpi_handle_by_name("top.mid", null)) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "IEEE 1364-2005 §26.6.34: a forever loop is a vpiForever, and spells its type" {
    var h: run.Harness = undefined;
    try h.init(
        \\module f;
        \\  reg r;
        \\  initial forever #5 r = ~r;
        \\endmodule
    );
    defer h.deinit();
    const procs = vpi_iterate(user.vpiProcess, vpi_handle_by_name("f", null));
    const init = vpi_scan(procs);
    _ = vpi_free_object(procs);
    const loop = vpi_handle(user.vpiStmt, init);
    try std.testing.expectEqual(user.vpiForever, vpi_get(vpiType, loop));
    try std.testing.expectEqualStrings("vpiForever", std.mem.span(vpi_get_str(vpiType, loop)));
}

test "§12.11: a continuous assignment's delays, derived where not written, and the counts refused" {
    var h: run.Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module d;
        \\  reg a;
        \\  wire w;
        \\  assign #(2, 7) w = a;
        \\endmodule
    );
    defer h.deinit();
    const assigns = vpi_iterate(user.vpiContAssign, vpi_handle_by_name("d", null));
    const ca = vpi_scan(assigns) orelse return error.TestUnexpectedResult;
    _ = vpi_free_object(assigns);
    var da: [3]abi.Time = undefined;
    var dl: abi.Delay = .{ .da = &da, .no_of_delays = 3, .time_type = user.vpiScaledRealTime, .mtm_flag = 0, .append_flag = 0, .pulsere_flag = 0 };
    delays.vpi_get_delays(ca, &dl);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    // Rise and fall as written; turn-off is IEEE 1364 §7.14's min(rise, fall).
    for (da, [_]f64{ 2, 7, 2 }) |t, want| try std.testing.expectEqual(want, t.real);
    for ([_]c_int{ 0, 4 }) |n| {
        dl.no_of_delays = n;
        delays.vpi_get_delays(ca, &dl);
        try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    }
}

test "§12.29: vpi_put_delays reaches the engine driver of a gate in a generated instance" {
    // The instance's model scope (1) is not its engine scope: the loop
    // iteration `b[0]` is an engine scope of its own between it and `top`.
    var h: run.Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module leaf; reg a; wire y; buf g(y, a); endmodule
        \\module top;
        \\  genvar i;
        \\  generate for (i = 0; i < 1; i = i + 1) begin : b
        \\    leaf u();
        \\  end endgenerate
        \\endmodule
    );
    defer h.deinit();
    const g = vpi_handle_by_name("top.b[0].u.g", null) orelse return error.TestUnexpectedResult;
    var da = [2]abi.Time{
        .{ .type = user.vpiSimTime, .high = 0, .low = 3, .real = 0 },
        .{ .type = user.vpiSimTime, .high = 0, .low = 4, .real = 0 },
    };
    var dl: abi.Delay = .{ .da = &da, .no_of_delays = 2, .time_type = user.vpiSimTime, .mtm_flag = 0, .append_flag = 0, .pulsere_flag = 0 };
    delays.vpi_put_delays(g, &dl);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    // The one driver the gate became: rise 3, fall 4, turn-off min(3, 4).
    const tok = (asObj(g) orelse return error.TestUnexpectedResult).src_tok;
    var hits: usize = 0;
    for (h.run.netlist.drivers) |drv| {
        if (drv.tok != tok) continue;
        hits += 1;
        try std.testing.expect(drv.delay.present);
        try std.testing.expectEqual(@as(u64, 3), drv.delay.rise);
        try std.testing.expectEqual(@as(u64, 4), drv.delay.fall);
        try std.testing.expectEqual(@as(u64, 3), drv.delay.off);
    }
    try std.testing.expectEqual(@as(usize, 1), hits);
}

test "§12.30/IEEE 1364 §19.8: a scaled time is in the unit of the object's own module, past a generate" {
    // `leaf` is in microseconds, `top` in nanoseconds, and the tick is the
    // finest precision, 1 ns. `u`'s model scope (1) is the engine's loop
    // iteration `b[0]`, a scope of `top`'s, so only the engine scope finds
    // `leaf`'s unit: 2 us is 2000 ticks, where `top`'s unit would make it 2.
    var h: run.Harness = undefined;
    try h.init(
        \\`timescale 1us/1ns
        \\module leaf; reg a; endmodule
        \\`timescale 1ns/1ns
        \\module top;
        \\  genvar i;
        \\  generate for (i = 0; i < 1; i = i + 1) begin : b
        \\    leaf u();
        \\  end endgenerate
        \\endmodule
    );
    defer h.deinit();
    const a = vpi_handle_by_name("top.b[0].u.a", null) orelse return error.TestUnexpectedResult;
    const two: abi.Time = .{ .type = user.vpiScaledRealTime, .high = 0, .low = 0, .real = 2 };
    try std.testing.expectEqual(@as(?u64, 2000), run.ticksOf(two, a));
}

test "IEEE 1364-2005 §1.7 Annex G: a name VerA does not answer is refused by that name" {
    var h: run.Harness = undefined;
    try h.init(
        \\module m(a);
        \\  input a;
        \\  wire w;
        \\endmodule
    );
    defer h.deinit();
    const m = vpi_handle_by_name("m", null) orelse return error.TestUnexpectedResult;
    const a = portNamed(m, "a") orelse return error.TestUnexpectedResult;
    // A property (vpi_get and vpi_get_str), an object or relationship
    // (vpi_handle and vpi_iterate) and a callback reason, each Annex G's.
    try std.testing.expectEqual(vpiUndefined, vpi_get(8, m));
    try std.testing.expect(std.mem.find(u8, lastMessage(), "vpiCellInstance") != null);
    try std.testing.expect(vpi_get_str(15, m) == null);
    try std.testing.expect(std.mem.find(u8, lastMessage(), "vpiDefFile") != null);
    try std.testing.expect(vpi_handle(98, a) == null);
    try std.testing.expect(std.mem.find(u8, lastMessage(), "vpiPortInst") != null);
    try std.testing.expect(vpi_iterate(127, m) == null);
    try std.testing.expect(std.mem.find(u8, lastMessage(), "vpiTaskFunc") != null);
    const save: abi.CbData = .{ .reason = 15, .cb_rtn = noCb, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(callback.vpi_register_cb(&save) == null);
    try std.testing.expect(std.mem.find(u8, lastMessage(), "cbStartOfSave") != null);
    // The legal neighbours on the same objects answer, with no error.
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiTopModule, m));
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    try std.testing.expect(vpi_iterate(user.vpiTask, m) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
}

test "§12.22: vpi_handle_multi(vpiInterModPath) is one path per port pair, holding its delays" {
    var h: run.Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module gate(a, y, w);
        \\  input a; output y; input [1:0] w;
        \\  buf (y, a);
        \\endmodule
        \\module top;
        \\  reg r; wire n, z; wire [1:0] v;
        \\  gate u1(r, n, v);
        \\  gate u2(n, z, v);
        \\endmodule
    );
    defer h.deinit();
    const y1 = portNamed(vpi_handle_by_name("top.u1", null), "y") orelse return error.TestUnexpectedResult;
    const a2 = portNamed(vpi_handle_by_name("top.u2", null), "a") orelse return error.TestUnexpectedResult;
    const w2 = portNamed(vpi_handle_by_name("top.u2", null), "w") orelse return error.TestUnexpectedResult;
    const multi = systf.vpi_handle_multi;
    const imp = user.vpiInterModPath;

    const p = multi(imp, y1, a2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    try std.testing.expectEqual(imp, vpi_get(vpiType, p));
    try std.testing.expectEqualStrings("vpiInterModPath", std.mem.span(vpi_get_str(vpiType, p)));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(p, multi(imp, y1, a2)));
    // IEEE 1364-2005 §26.6.16: ->> its ports, the output first.
    const itr = vpi_iterate(vpiPort, p);
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_scan(itr), y1));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_scan(itr), a2));
    try std.testing.expect(vpi_scan(itr) == null);
    try std.testing.expect(vpi_handle(vpiModule, p) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));

    // No put yet: no delay. Then two, turn-off §7.14's min(rise, fall).
    var da: [9]abi.Time = undefined;
    var dl: abi.Delay = .{ .da = &da, .no_of_delays = 3, .time_type = user.vpiScaledRealTime, .mtm_flag = 0, .append_flag = 0, .pulsere_flag = 0 };
    delays.vpi_get_delays(p, &dl);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    for (da[0..3]) |t| try std.testing.expectEqual(@as(f64, 0), t.real);
    const before = h.bag.count();
    da[0] = .{ .type = user.vpiScaledRealTime, .high = 0, .low = 0, .real = 4 };
    da[1] = .{ .type = user.vpiScaledRealTime, .high = 0, .low = 0, .real = 2 };
    dl.no_of_delays = 2;
    delays.vpi_put_delays(p, &dl);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    dl.no_of_delays = 3;
    delays.vpi_get_delays(p, &dl);
    for (da[0..3], [_]f64{ 4, 2, 2 }) |t, want| try std.testing.expectEqual(want, t.real);
    // The put is not silent: the run's diagnostics say no simulation applies it.
    try std.testing.expectEqual(before + 1, h.bag.count());
    try std.testing.expectEqual(vera.diag.Code.W0251, h.bag.at(before).code);
    // Read in ticks: 4 ns is 4 ticks of the 1 ns precision.
    dl.time_type = user.vpiSimTime;
    delays.vpi_get_delays(p, &dl);
    try std.testing.expectEqual(@as(c_uint, 4), da[0].low);
    // Pulse limits other than the delay are refused, not dropped.
    dl.time_type = user.vpiScaledRealTime;
    dl.pulsere_flag = 1;
    for (&da, 0..) |*t, k| t.* = .{ .type = user.vpiScaledRealTime, .high = 0, .low = 0, .real = @floatFromInt(k) };
    delays.vpi_put_delays(p, &dl);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));

    // Not a path: an input first, one port twice, two sizes, a non-port.
    try std.testing.expect(multi(imp, a2, y1) == null);
    try std.testing.expect(std.mem.find(u8, lastMessage(), "not an output or inout port") != null);
    try std.testing.expect(multi(imp, y1, y1) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expect(multi(imp, y1, w2) == null);
    try std.testing.expect(std.mem.find(u8, lastMessage(), "same size") != null);
    try std.testing.expect(multi(imp, vpi_handle_by_name("top.n", null), a2) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "every vpi_user.h constant the Zig side spells has the header's value" {
    // The header's integer macros: `#define NAME <int>`, decimal or `0x` hex,
    // signed, at most one pair of parentheses. Aliases (`vpiSysFuncInt`),
    // include guards and the `PLI_*` macros are not integers and are skipped.
    const gpa = std.testing.allocator;
    var macros: std.StringHashMapUnmanaged(c_int) = .empty;
    defer macros.deinit(gpa);
    const header = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, @import("repo_options").repo_root ++ "/src/vpi/vpi_user.h", gpa, .unlimited);
    defer gpa.free(header);
    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        if (!std.mem.eql(u8, words.next() orelse continue, "#define")) continue;
        const name = words.next() orelse continue;
        const text = std.mem.trim(u8, words.next() orelse continue, "()");
        const v = std.fmt.parseInt(c_int, text, 0) catch continue;
        const gop = try macros.getOrPut(gpa, name);
        // One name, one number: a second `#define` must agree with the first.
        if (gop.found_existing) try std.testing.expectEqual(gop.value_ptr.*, v);
        gop.value_ptr.* = v;
    }
    // The parser, against values read off the header by hand: line 124
    // `vpiModule 32`, line 449 `vpiUndefined -1`, line 606 `vpiSupplyDrive
    // 0x80` = 128, and Annex G's edge masks, whose unions are the header's own
    // `vpiPosedge 0x0D` and `vpiNegedge 0x32` = 50.
    try std.testing.expectEqual(@as(?c_int, 32), macros.get("vpiModule"));
    try std.testing.expectEqual(@as(?c_int, -1), macros.get("vpiUndefined"));
    try std.testing.expectEqual(@as(?c_int, 128), macros.get("vpiSupplyDrive"));
    try std.testing.expectEqual(macros.get("vpiPosedge").?, macros.get("vpiEdge01").? | macros.get("vpiEdge0x").? | macros.get("vpiEdgex1").?);
    try std.testing.expectEqual(@as(?c_int, 50), macros.get("vpiNegedge"));
    try std.testing.expectEqual(macros.get("vpiNegedge").?, macros.get("vpiEdge10").? | macros.get("vpiEdge1x").? | macros.get("vpiEdgex0").?);

    // Every `pub` c_int vpi_user.zig spells as a header name (Zig 0.17
    // reflection sees `pub` decls only). A `vpi*`/`cb*` name the header does
    // not define is an error too: VerA's own numbers in that namespace
    // (`vpiQuantity`, `vpiExpStrVal`) are in the header. The `acb*` analog
    // reasons are not: tests/conformance/tests/verilog-ams/ch12_vpi_routines/p03_vpi_analog.h
    // defines them, outside this module's directory.
    @setEvalBranchQuota(100_000);
    var checked: usize = 0;
    inline for (.{user}) |file| {
        inline for (comptime std.meta.declarations(file)) |name| {
            if (comptime !isHeaderSpelling(name)) continue;
            if (comptime @TypeOf(@field(file, name)) != c_int) continue;
            if (macros.get(name)) |want| {
                std.testing.expectEqual(want, @field(file, name)) catch |e| {
                    std.debug.print("{s}: vpi_user.h says {d}\n", .{ name, want });
                    return e;
                };
                checked += 1;
            } else if (comptime !std.mem.startsWith(u8, name, "acb")) {
                std.debug.print("{s} is not a vpi_user.h integer macro\n", .{name});
                return error.TestUnexpectedResult;
            }
        }
    }
    // 2026-10-31: 334, every `pub` c_int of vpi_user.zig less the six
    // `acb*` (before it, seven files spelled 12 of these twice, so the
    // floor of 345 counted those twice and left out the private
    // vpiExpStrVal). A floor, so a reflection that finds nothing cannot pass.
    try std.testing.expect(checked >= 334);
}

// ---------------------------------------------------------------------------
// Corner cases of root.zig's error status and delays.zig's puts, over
// digital designs run through `run.Harness`.
// ---------------------------------------------------------------------------

test "§12.2: a message past Figure 12-1's buffer is truncated and still NUL-terminated" {
    session.close();
    const long: [600]u8 = @splat('x');
    status.fail("LONG", "{s}", .{&long});
    var info: abi.ErrorInfo = undefined;
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(&info));
    try std.testing.expectEqual(@as(usize, 511), std.mem.span(info.message).len);
    try std.testing.expectEqualStrings("LONG", std.mem.span(info.code));
    // vpi_chk_error leaves the status; the next routine clears it.
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 0), trust.vpi_compare_objects(null, null));
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(&info));
    try std.testing.expectEqualStrings("BADHANDLE", std.mem.span(info.code));
    status.clearError();
    try std.testing.expectEqual(@as(c_int, 0), status.vpi_chk_error(&info));
    try std.testing.expect(info.message == null and info.code == null);
}

test "§12.29: a delay put in ticks reads back in the module's time unit" {
    var h: run.Harness = undefined;
    try h.init(
        \\`timescale 1us/1ns
        \\module top; reg a; wire y; buf g(y, a); endmodule
    );
    defer h.deinit();
    const g = handle.vpi_handle_by_name("top.g", null) orelse return error.TestUnexpectedResult;
    // 2000 and 3000 ticks of the 1 ns precision: 2 and 3 us.
    var da = [3]Time{ ticks(2000), ticks(3000), ticks(0) };
    var dl = delayOf(&da, 2, user.vpiSimTime);
    delays.vpi_put_delays(g, &dl);
    try std.testing.expectEqual(@as(c_int, 0), status.vpi_chk_error(null));
    dl = delayOf(&da, 3, user.vpiScaledRealTime);
    delays.vpi_get_delays(g, &dl);
    try std.testing.expectEqual(@as(c_int, 0), status.vpi_chk_error(null));
    for (da, [_]f64{ 2, 3, 2 }) |t, want| try std.testing.expectEqual(want, t.real);
}

test "§12.29: a delay that is NaN, infinite or negative is refused, and the held one stays" {
    var h: run.Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module leaf(a, y); input a; output y; buf (y, a);
        \\  specify (a => y) = 5; endspecify
        \\endmodule
        \\module top; reg r; wire n, z; leaf first_cell(r, n); leaf second_cell(n, z); endmodule
    );
    defer h.deinit();
    const first_cell = handle.vpi_handle_by_name("top.first_cell", null);
    const second_cell = handle.vpi_handle_by_name("top.second_cell", null);
    const path = nth(user.vpiModPath, first_cell, 0) orelse return error.TestUnexpectedResult;
    // first_cell's output `y` into second_cell's input `a`.
    const imp = systf.vpi_handle_multi(user.vpiInterModPath, nth(user.vpiPort, first_cell, 1), nth(user.vpiPort, second_cell, 0)) orelse return error.TestUnexpectedResult;
    var da: [3]Time = undefined;
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -1 }) |bad| {
        // A module path: one delay. An inter-module path: two.
        da = .{ scaled(bad), scaled(bad), scaled(bad) };
        var dl = delayOf(&da, 1, user.vpiScaledRealTime);
        delays.vpi_put_delays(path, &dl);
        try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
        dl.no_of_delays = 2;
        delays.vpi_put_delays(imp, &dl);
        try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    }
    var dl = delayOf(&da, 1, user.vpiScaledRealTime);
    delays.vpi_get_delays(path, &dl);
    try std.testing.expectEqual(@as(f64, 5), da[0].real);
    dl.no_of_delays = 2;
    delays.vpi_get_delays(imp, &dl);
    try std.testing.expectEqual(@as(f64, 0), da[0].real);
}

test "§26.6.26 b): a text nested past vpi_get_str's buffer is refused by its length, not by the stack" {
    // Oracle: every decompiled level writes at least one byte of its own, so
    // `a + a + ... + a` 10^4 operators deep (4 * 10^4 bytes) cannot fit the
    // 4095-byte buffer: vpi_get_str answers null with an error, as for any
    // text past it. The rewrite recursed to the chain's bottom before
    // writing a byte and overflowed the caller's stack.
    // The depth: 10^4 overflows an 8 MiB caller stack under the rewrite's
    // recursive walks (measured, Debug: each of the three segfaults at 10,000) and
    // elaborates on the smallest reservation runGuarded takes on a CI
    // machine (256 MiB, Windows': measured, these designs elaborate there
    // to 20,000 and not at 50,000), so the result does not depend on the
    // machine's memory.
    const n = 10_000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "module t;\n  wire a;\n  wire w;\n  assign w = a");
    for (0..n) |_| try src.appendSlice(std.testing.allocator, " + a");
    try src.appendSlice(std.testing.allocator, ";\nendmodule\n");
    var h: run.Harness = undefined;
    try h.init(src.items);
    defer h.deinit();
    const itr = iterate.vpi_iterate(user.vpiContAssign, handle.vpi_handle_by_name("t", null));
    const assign = iterate.vpi_scan(itr) orelse return error.TestUnexpectedResult;
    _ = trust.vpi_free_object(itr);
    try std.testing.expect(property.vpi_get_str(user.vpiDecompile, handle.vpi_handle(user.vpiRhs, assign)) == null);
    try std.testing.expect(status.vpi_chk_error(null) != 0);
}

test "§26.6.23 vpiLoad finds an assign that reads a net 10^4 operators deep, on the caller's stack" {
    // Oracle: IEEE 1364-2005 §26.6.23, a net's loads are the continuous
    // assignments whose right side reads it: `w = b + b + ... + a` reads `a`
    // once, at the bottom of the chain, and `b` at every level. The rewrite
    // walked the operands recursively and overflowed the caller's stack.
    // The depth: 10^4 overflows an 8 MiB caller stack under the rewrite's
    // recursive walks (measured, Debug: each of the three segfaults at 10,000) and
    // elaborates on the smallest reservation runGuarded takes on a CI
    // machine (256 MiB, Windows': measured, these designs elaborate there
    // to 20,000 and not at 50,000), so the result does not depend on the
    // machine's memory.
    const n = 10_000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "module t;\n  wire a, b;\n  wire w;\n  assign w = a");
    for (0..n) |_| try src.appendSlice(std.testing.allocator, " + b");
    try src.appendSlice(std.testing.allocator, ";\nendmodule\n");
    var h: run.Harness = undefined;
    try h.init(src.items);
    defer h.deinit();
    const loads = iterate.vpi_iterate(user.vpiLoad, handle.vpi_handle_by_name("t.a", null)) orelse return error.TestUnexpectedResult;
    const first = iterate.vpi_scan(loads) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(c_int, user.vpiContAssign), property.vpi_get(user.vpiType, first));
    try std.testing.expect(iterate.vpi_scan(loads) == null);
}

test "§26.6.27: 10^4 nested begin blocks build their model on the reserved stack, one vpiBegin a level" {
    // Oracle: the source, counted. `initial begin begin ... x = 1; end end`
    // n deep is n vpiBegin objects, each the one statement of its parent
    // (IEEE 1364-2005 §26.6.27 begin ->> vpiStmt), and the assignment at the
    // bottom. The rewrite built the model on the caller's stack, one
    // recursion a level, and overflowed it.
    // The depth: 10^4 overflows an 8 MiB caller stack under the rewrite's
    // recursive walks (measured, Debug: each of the three segfaults at 10,000) and
    // elaborates on the smallest reservation runGuarded takes on a CI
    // machine (256 MiB, Windows': measured, these designs elaborate there
    // to 20,000 and not at 50,000), so the result does not depend on the
    // machine's memory.
    const n = 10_000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "module t;\n  reg x;\n  initial ");
    for (0..n) |_| try src.appendSlice(std.testing.allocator, "begin ");
    try src.appendSlice(std.testing.allocator, "x = 1;");
    for (0..n) |_| try src.appendSlice(std.testing.allocator, " end");
    try src.appendSlice(std.testing.allocator, "\nendmodule\n");
    var h: run.Harness = undefined;
    try h.init(src.items);
    defer h.deinit();
    const procs = iterate.vpi_iterate(user.vpiProcess, handle.vpi_handle_by_name("t", null));
    var s = handle.vpi_handle(user.vpiStmt, iterate.vpi_scan(procs));
    _ = trust.vpi_free_object(procs);
    var begins: usize = 0;
    while (property.vpi_get(user.vpiType, s) == user.vpiBegin) : (begins += 1) {
        try std.testing.expect(begins < n);
        const inner = iterate.vpi_iterate(user.vpiStmt, s);
        s = iterate.vpi_scan(inner);
        try std.testing.expect(iterate.vpi_scan(inner) == null);
    }
    try std.testing.expectEqual(@as(usize, n), begins);
    try std.testing.expectEqual(@as(c_int, user.vpiAssignment), property.vpi_get(user.vpiType, s));
}

test "§12.31.1: a word whose index passes a PLI_INT32 calls no cbValueChange, and says why" {
    // Oracle: §12.31.1's index is `s_cb_data.index`, a PLI_INT32, and §4.9
    // bounds an array by any constant: 2^32 has no PLI_INT32 to report. A
    // word in range still reports. The rewrite @intCast the index and trapped.
    var h: run.Harness = undefined;
    try h.init(
        \\module t;
        \\  reg [7:0] m [4294967296:4294967297];
        \\  reg [7:0] n [0:1];
        \\  initial begin #1 m[4294967296] = 1; n[1] = 2; end
        \\endmodule
    );
    defer h.deinit();
    const S = struct {
        var calls: u32 = 0;
        fn countChange(cd: *abi.CbData) callconv(.c) c_int {
            std.debug.assert(cd.reason == user.cbValueChange);
            calls += 1;
            return 0;
        }
    };
    S.calls = 0;
    var v: abi.Value = .{ .format = user.vpiIntVal, .value = .{ .integer = 0 } };
    for ([_][*:0]const u8{ "t.m", "t.n" }) |name| {
        const d: abi.CbData = .{ .reason = user.cbValueChange, .cb_rtn = S.countChange, .obj = handle.vpi_handle_by_name(name, null), .time = null, .value = &v, .index = 0, .user_data = null };
        try std.testing.expect(callback.vpi_register_cb(&d) != null);
    }
    try run.simulate();
    try std.testing.expectEqual(@as(u32, 1), S.calls);
    try std.testing.expect(status.vpi_chk_error(null) != 0);
}

test "§12.18 runMixed refuses a transient whose grid has no integer step count, before it touches the library" {
    // Oracle: the window by hand. `tran 0 1 1e-300` is 10^300 steps,
    // past any usize and past tran_steps_max; `tran 1 1` and `tran 0 nan`
    // are no forward window. The rewrite's @intFromFloat panicked.
    var b: root.Binding = .{};
    for ([_]root.analog.Analysis{
        .{ .kind = .tran, .start = 0, .stop = 1, .max_step = 1e-300 },
        .{ .kind = .tran, .start = 1, .stop = 1 },
        .{ .kind = .tran, .start = 0, .stop = std.math.nan(f64) },
        .{ .kind = .tran, .start = -1, .stop = 1 },
    }) |a| try std.testing.expectError(error.BadAnalysis, b.runMixed(a, undefined, 1e-9, &.{}, &.{}));
}

test "§26.6.5 a digital port's vpiLowConn is its module's net of that name, its vpiHighConn the parent's connected net" {
    // Oracle: IEEE 1364-2005 §26.6.5 (port -> vpiLowConn the expression
    // inside the module, vpiHighConn the instance's connected one) and
    // the source: `leaf u(.a(bus), .y(s))` connects leaf's `a` to
    // top's `bus` and `y` to `s`, names that differ, so a name match
    // gives the wrong answer. The rewrite refused vpiLowConn.
    var h: run.Harness = undefined;
    try h.init(
        \\module leaf(a, y); input [3:0] a; output y; assign y = a[0]; endmodule
        \\module top; wire [3:0] bus; wire s; leaf u(.a(bus), .y(s)); endmodule
    );
    defer h.deinit();
    const itr = iterate.vpi_iterate(user.vpiPort, handle.vpi_handle_by_name("top.u", null)) orelse return error.TestUnexpectedResult;
    const a = iterate.vpi_scan(itr) orelse return error.TestUnexpectedResult;
    const y = iterate.vpi_scan(itr) orelse return error.TestUnexpectedResult;
    try std.testing.expect(iterate.vpi_scan(itr) == null);
    try std.testing.expectEqualStrings("top.u.a", connName(user.vpiLowConn, a));
    try std.testing.expectEqual(@as(c_int, user.vpiNet), property.vpi_get(user.vpiType, handle.vpi_handle(user.vpiLowConn, a)));
    try std.testing.expectEqualStrings("top.bus", connName(user.vpiHighConn, a));
    try std.testing.expectEqualStrings("top.u.y", connName(user.vpiLowConn, y));
    try std.testing.expectEqualStrings("top.s", connName(user.vpiHighConn, y));
}

test "§26.6.5 an analog port's vpiHighConn is the parent's connected net, and a top port's vpiLowConn its node" {
    // Oracle: the source, as above: `sub u(p, n)` connects sub's `a` to
    // top's `p` and `b` to `n`. A top-level port has no instance, so no
    // vpiHighConn; its vpiLowConn is its node (VAMS §11.6.4 port ->
    // nodes: a top port's node has no net).
    var res = try openSource(nested_src);
    defer res.deinit(std.testing.allocator);
    defer close();
    const itr = iterate.vpi_iterate(user.vpiPort, handle.vpi_handle_by_name("top.u", null)) orelse return error.TestUnexpectedResult;
    const a = iterate.vpi_scan(itr) orelse return error.TestUnexpectedResult;
    const b = iterate.vpi_scan(itr) orelse return error.TestUnexpectedResult;
    _ = trust.vpi_free_object(itr);
    try std.testing.expectEqualStrings("top.p", connName(user.vpiHighConn, a));
    try std.testing.expectEqualStrings("top.n", connName(user.vpiHighConn, b));
    const tops = iterate.vpi_iterate(user.vpiPort, handle.vpi_handle_by_name("top", null)) orelse return error.TestUnexpectedResult;
    const p = iterate.vpi_scan(tops) orelse return error.TestUnexpectedResult;
    _ = trust.vpi_free_object(tops);
    try std.testing.expectEqualStrings("top.p", connName(user.vpiLowConn, p));
    try std.testing.expectEqual(@as(c_int, user.vpiNode), property.vpi_get(user.vpiType, handle.vpi_handle(user.vpiLowConn, p)));
    try std.testing.expect(handle.vpi_handle(user.vpiHighConn, p) == null);
}

test "§3.7.1 vpiName is an escaped identifier's name, and vpiFullName reads back by name: `\\a`, `$q`, `m.1`" {
    // Oracle: IEEE 1364-2005 §3.7.1, neither the leading `\` nor the
    // closing white space is part of the name: `\\a ` is `\a`, `\$q ` is
    // `$q`, `\m.1 ` is `m.1`. The parser interns the first two with a `\`
    // of their own (front's interning, 0.22), which vpiName showed.
    var h: run.Harness = undefined;
    try h.init("module t;\n  wire \\\\a , \\$q , \\m.1 ;\nendmodule\n");
    defer h.deinit();
    const itr = iterate.vpi_iterate(user.vpiNet, handle.vpi_handle_by_name("t", null)) orelse return error.TestUnexpectedResult;
    var names: [3][]const u8 = .{ "", "", "" };
    defer for (names) |n| std.testing.allocator.free(n);
    for (&names) |*name| {
        const net = iterate.vpi_scan(itr) orelse return error.TestUnexpectedResult;
        name.* = try std.testing.allocator.dupe(u8, std.mem.span(property.vpi_get_str(user.vpiName, net)));
        const full = try std.testing.allocator.dupeSentinel(u8, std.mem.span(property.vpi_get_str(user.vpiFullName, net)), 0);
        defer std.testing.allocator.free(full);
        const back = handle.vpi_handle_by_name(full.ptr, null);
        try std.testing.expect(back != null);
        try std.testing.expect(trust.vpi_compare_objects(back, net) != 0);
    }
    try std.testing.expect(iterate.vpi_scan(itr) == null);
    try std.testing.expectEqualStrings("\\a", names[0]);
    try std.testing.expectEqualStrings("$q", names[1]);
    try std.testing.expectEqualStrings("m.1", names[2]);
}
