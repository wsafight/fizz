/// Model contract validation.
const std = @import("std");
const msg = @import("msg.zig");
const cmd = @import("cmd.zig");
const view_mod = @import("view.zig");

/// Update return type: supports returning both a new Model and Cmd (equivalent to Go's (Model, Cmd)).
pub fn UpdateResult(comptime ModelType: type) type {
    return struct {
        model: ?ModelType = null,
        cmd: ?cmd.Cmd = null,
    };
}

pub fn validateModel(comptime ModelType: type) void {
    const Ptr = *ModelType;

    if (!@hasDecl(ModelType, "init")) {
        @compileError("Model missing init method: expected fn init(*Self) ?Cmd");
    } else {
        const info = @typeInfo(@TypeOf(@field(ModelType, "init"))).@"fn";
        if (info.params.len != 1 or info.params[0].type != Ptr)
            @compileError("Model.init signature error: expected fn init(*Self) ?Cmd");
        if (info.return_type != ?cmd.Cmd)
            @compileError("Model.init return type error: expected ?Cmd");
    }

    if (!@hasDecl(ModelType, "update")) {
        @compileError("Model missing update method");
    } else {
        const info = @typeInfo(@TypeOf(@field(ModelType, "update"))).@"fn";
        if (info.params.len == 3) {
            // update(*Self, Msg, Allocator) — arena-aware variant
            if (info.params[0].type != Ptr or info.params[1].type != msg.Msg or info.params[2].type != std.mem.Allocator)
                @compileError("Model.update signature error: expected fn update(*Self, Msg, Allocator) ?Cmd or UpdateResult");
        } else if (info.params.len == 2) {
            if (info.params[0].type != Ptr or info.params[1].type != msg.Msg)
                @compileError("Model.update signature error: expected fn update(*Self, Msg) ?Cmd or UpdateResult");
        } else {
            @compileError("Model.update signature error: expected 2 or 3 parameters");
        }
        const rt = info.return_type orelse @compileError("Model.update must have a return value");
        if (rt != ?cmd.Cmd and rt != UpdateResult(ModelType))
            @compileError("Model.update return type error: expected ?Cmd or UpdateResult(Self)");
    }

    if (!@hasDecl(ModelType, "view")) {
        @compileError("Model missing view method: expected fn view(*Self) View or []const u8");
    } else {
        const info = @typeInfo(@TypeOf(@field(ModelType, "view"))).@"fn";
        if (info.params.len == 2) {
            // view(*Self, Allocator) — arena-aware variant
            if (info.params[0].type != Ptr or info.params[1].type != std.mem.Allocator)
                @compileError("Model.view signature error: expected fn view(*Self, Allocator) View or []const u8");
        } else if (info.params.len == 1) {
            if (info.params[0].type != Ptr)
                @compileError("Model.view signature error: expected fn view(*Self) View or []const u8");
        } else {
            @compileError("Model.view signature error: expected 1 or 2 parameters");
        }

        const rt = info.return_type orelse @compileError("Model.view must have a return value");
        if (rt != []const u8 and rt != view_mod.View)
            @compileError("Model.view return type error: only []const u8 or tea.view.View supported");
    }
}

pub fn returnsStructuredView(comptime ModelType: type) bool {
    const info = @typeInfo(@TypeOf(@field(ModelType, "view"))).@"fn";
    const rt = info.return_type.?;
    return rt == view_mod.View;
}

pub fn viewTakesAllocator(comptime ModelType: type) bool {
    const info = @typeInfo(@TypeOf(@field(ModelType, "view"))).@"fn";
    return info.params.len == 2;
}

pub fn updateTakesAllocator(comptime ModelType: type) bool {
    const info = @typeInfo(@TypeOf(@field(ModelType, "update"))).@"fn";
    return info.params.len == 3;
}

pub fn viewOf(comptime ModelType: type, model: *ModelType, alloc: std.mem.Allocator) view_mod.View {
    if (comptime viewTakesAllocator(ModelType)) {
        if (comptime returnsStructuredView(ModelType)) {
            return model.view(alloc);
        }
        return view_mod.View.init(model.view(alloc));
    }
    if (comptime returnsStructuredView(ModelType)) {
        return model.view();
    }
    return view_mod.View.init(model.view());
}

pub fn hasDeinit(comptime ModelType: type) bool {
    return @hasDecl(ModelType, "deinit");
}

pub fn returnsUpdateResult(comptime ModelType: type) bool {
    const info = @typeInfo(@TypeOf(@field(ModelType, "update"))).@"fn";
    return info.return_type.? == UpdateResult(ModelType);
}

/// Call model.update and handle both return types.
/// If a new model is returned, replace the destination.
pub fn callUpdate(comptime ModelType: type, model: *ModelType, m: msg.Msg, alloc: std.mem.Allocator) ?cmd.Cmd {
    if (comptime returnsUpdateResult(ModelType)) {
        const result = if (comptime updateTakesAllocator(ModelType))
            model.update(m, alloc)
        else
            model.update(m);
        if (result.model) |new_model| model.* = new_model;
        return result.cmd;
    } else {
        if (comptime updateTakesAllocator(ModelType))
            return model.update(m, alloc)
        else
            return model.update(m);
    }
}

const testing = @import("std").testing;

const SliceViewModel = struct {
    pub fn init(_: *SliceViewModel) ?cmd.Cmd {
        return null;
    }

    pub fn update(_: *SliceViewModel, _: msg.Msg) ?cmd.Cmd {
        return null;
    }

    pub fn view(_: *SliceViewModel) []const u8 {
        return "slice";
    }
};

const StructuredViewModel = struct {
    pub fn init(_: *StructuredViewModel) ?cmd.Cmd {
        return null;
    }

    pub fn update(_: *StructuredViewModel, _: msg.Msg) ?cmd.Cmd {
        return null;
    }

    pub fn view(_: *StructuredViewModel) view_mod.View {
        return view_mod.View.init("struct");
    }
};

test "validateModel: supports []const u8 view" {
    comptime validateModel(SliceViewModel);
}

test "validateModel: supports View return" {
    comptime validateModel(StructuredViewModel);
}

test "viewOf: adapts both kinds" {
    var a = SliceViewModel{};
    var b = StructuredViewModel{};
    const dummy_alloc = std.testing.allocator;
    try testing.expectEqualStrings("slice", viewOf(SliceViewModel, &a, dummy_alloc).content);
    try testing.expectEqualStrings("struct", viewOf(StructuredViewModel, &b, dummy_alloc).content);
}

const ArenaViewModel = struct {
    pub fn init(_: *ArenaViewModel) ?cmd.Cmd {
        return null;
    }

    pub fn update(_: *ArenaViewModel, _: msg.Msg, _: std.mem.Allocator) ?cmd.Cmd {
        return null;
    }

    pub fn view(_: *ArenaViewModel, _: std.mem.Allocator) []const u8 {
        return "arena";
    }
};

test "validateModel: supports arena-aware signatures" {
    comptime validateModel(ArenaViewModel);
}

test "viewOf: arena-aware model" {
    var m = ArenaViewModel{};
    const alloc = std.testing.allocator;
    try testing.expectEqualStrings("arena", viewOf(ArenaViewModel, &m, alloc).content);
}
