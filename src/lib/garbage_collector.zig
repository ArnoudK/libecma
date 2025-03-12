const interp = @import("interpreter.zig");
const Value = interp.Value;

const std = @import("std");

pub const JSObject = struct {
    values: std.StringHashMap(Value),
    marked: bool = false,
};

pub const JSArray = struct {
    marked: bool = false,
    values: []Value,
};

pub const GCTypes = union(enum) {
    JSObject: *JSObject,
    JSString: []const u8,
    Raw: []const u8,
    JSArray: *JSArray,
    JSEnv: *JSEnv, // Add JSEnv to the GC types
};

pub const GCNode = struct {
    type: GCTypes,
    next: ?*GCNode,
    marked: bool = false,
};

pub const GarbageCollector = struct {
    allocator: std.mem.Allocator,
    objects: ?*GCNode = null,
    bytes_allocated: usize = 0,
    bytes_threshold: usize = 1024 * 1024, // 1MB initial threshold

    pub fn init(allocator: std.mem.Allocator) GarbageCollector {
        return GarbageCollector{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GarbageCollector) void {
        var obj = self.objects;
        while (obj) |node| {
            const next = node.next;
            self.freeNode(node);
            obj = next;
        }
    }

    // Allocate a JSObject and track it for GC
    pub fn allocObject(self: *GarbageCollector) !*JSObject {
        const obj = try self.allocator.create(JSObject);
        obj.* = JSObject{
            .values = std.StringHashMap(Value).init(self.allocator),
        };

        try self.trackObject(GCTypes{ .JSObject = obj });
        return obj;
    }

    // Allocate a string and track it for GC
    pub fn allocString(self: *GarbageCollector, str: []const u8) ![]const u8 {
        const string = try self.allocator.dupe(u8, str);
        try self.trackObject(GCTypes{ .JSString = string });
        return string;
    }

    // Allocate raw memory and track it for GC
    pub fn allocRaw(self: *GarbageCollector, size: usize) ![]u8 {
        const mem = try self.allocator.alloc(u8, size);
        try self.trackObject(GCTypes{ .Raw = mem });
        return mem;
    }

    // Allocate a JSArray and track it for GC
    pub fn allocArray(self: *GarbageCollector, size: usize) !*JSArray {
        const values = try self.allocator.alloc(Value, size);
        const array = try self.allocator.create(JSArray);
        array.* = JSArray{
            .values = values,
            .marked = false,
        };

        try self.trackObject(GCTypes{ .JSArray = array });
        return array;
    }

    // Allocate a JSEnv and track it for GC
    pub fn allocEnv(self: *GarbageCollector, parent: ?*JSEnv) !*JSEnv {
        const env = try self.allocator.create(JSEnv);
        env.* = JSEnv{
            .values = std.StringHashMap(Value).init(self.allocator),
            .parent = parent,
            .marked = false,
        };

        try self.trackObject(GCTypes{ .JSEnv = env });
        return env;
    }

    // Track an object in the GC
    fn trackObject(self: *GarbageCollector, obj_type: GCTypes) !void {
        const size = switch (obj_type) {
            .JSObject => @sizeOf(JSObject),
            .JSString => |str| str.len,
            .Raw => |raw| raw.len,
            .JSArray => |arr| arr.values.len * @sizeOf(Value) + @sizeOf(JSArray),
            .JSEnv => @sizeOf(JSEnv),
        };

        const node = try self.allocator.create(GCNode);
        node.* = .{
            .type = obj_type,
            .next = self.objects,
            .marked = false,
        };

        self.objects = node;
        self.bytes_allocated += size;

        if (self.bytes_allocated > self.bytes_threshold) {
            try self.collectGarbage();
        }
    }

    // Free a specific node and its associated memory
    fn freeNode(self: *GarbageCollector, node: *GCNode) void {
        const size = switch (node.type) {
            .JSObject => |obj| blk: {
                obj.values.deinit();
                self.allocator.destroy(obj);
                break :blk @sizeOf(JSObject);
            },
            .JSString => |str| blk: {
                const len = str.len;
                self.allocator.free(str);
                break :blk len;
            },
            .Raw => |raw| blk: {
                const len = raw.len;
                self.allocator.free(raw);
                break :blk len;
            },
            .JSArray => |arr| blk: {
                const len = arr.values.len * @sizeOf(Value) + @sizeOf(JSArray);
                self.allocator.free(arr.values);
                self.allocator.destroy(arr);
                break :blk len;
            },
            .JSEnv => |env| blk: {
                env.values.deinit();
                self.allocator.destroy(env);
                break :blk @sizeOf(JSEnv);
            },
        };

        self.bytes_allocated -= size;
        self.allocator.destroy(node);
    }

    // Mark all objects reachable from roots
    pub fn markRoots(self: *GarbageCollector, roots: []const Value) void {
        for (roots) |root| {
            self.markValue(root);
        }
    }

    // Mark a single value if it's a reference type
    fn markValue(self: *GarbageCollector, value: Value) void {
        // Handle reference types based on your Value enum
        // This is an example implementation
        switch (value) {
            .Object => |obj| self.markObject(obj),
            .String => |str| self.markString(str),
            .Array => |arr| self.markJSArray(arr),
            .Function => |func| self.markJSEnv(func.closure),
            .NativeFunction => |func| if (func.closure) |closure| self.markJSEnv(closure),
            else => {}, // primitive types don't need marking
        }
    }

    // Find and mark a JSObject node
    fn markObject(self: *GarbageCollector, obj: *JSObject) void {
        // Already marked - prevent cycles
        if (obj.marked) return;

        // Mark the object
        obj.marked = true;

        // Find and mark the GC node
        _ = self.markNodeForObject(obj);

        // Mark all values contained in the object
        var it = obj.values.iterator();
        while (it.next()) |entry| {
            self.markValue(entry.value_ptr.*);
        }
    }

    // Find and mark the node for a string
    fn markString(self: *GarbageCollector, str: []const u8) void {
        _ = self.markNodeForPointer(str.ptr);
    }

    // Mark an array and its contents
    fn markArray(self: *GarbageCollector, array: []Value) void {
        var node = self.markNodeForPointer(array.ptr);
        if (node == null or node.?.marked) return;

        node.?.marked = true;

        // Mark all values in the array
        for (array) |item| {
            self.markValue(item);
        }
    }

    // Mark a JSArray and its contents
    fn markJSArray(self: *GarbageCollector, array: *JSArray) void {
        // Already marked - prevent cycles
        if (array.marked) return;

        // Mark the array struct
        array.marked = true;

        // Find and mark the GC node
        var current = self.objects;
        while (current) |node| {
            if (node.type == .JSArray and node.type.JSArray == array) {
                node.marked = true;
                break;
            }
            current = node.next;
        }

        // Mark all values in the array
        for (array.values) |item| {
            self.markValue(item);
        }
    }

    // Mark environment and all variables in it
    fn markJSEnv(self: *GarbageCollector, env: *JSEnv) void {
        // Already marked - prevent cycles
        if (env.marked) return;

        // Mark the environment
        env.marked = true;

        // Find and mark the GC node
        var current = self.objects;
        while (current) |node| {
            if (node.type == .JSEnv and node.type.JSEnv == env) {
                node.marked = true;
                break;
            }
            current = node.next;
        }

        // Mark parent environment if exists
        if (env.parent) |parent| {
            self.markJSEnv(parent);
        }

        // Mark all values in the environment
        var it = env.values.valueIterator();
        while (it.next()) |value| {
            self.markValue(value.*);
        }
    }

    // Find and mark the GC node for an object
    fn markNodeForObject(self: *GarbageCollector, obj: *JSObject) ?*GCNode {
        var current = self.objects;
        while (current) |node| {
            if (node.type == .JSObject and node.type.JSObject == obj) {
                node.marked = true;
                return node;
            }
            current = node.next;
        }
        return null;
    }

    // Find and mark the GC node containing a pointer
    fn markNodeForPointer(self: *GarbageCollector, ptr: *const anyopaque) ?*GCNode {
        var current = self.objects;
        while (current) |node| {
            switch (node.type) {
                .JSString => |str| {
                    const str_as_anyopaque: *const anyopaque = (@ptrCast(str.ptr));
                    if (str_as_anyopaque == ptr) {
                        node.marked = true;
                        return node;
                    }
                },
                .Raw => |raw| {
                    const raw_as_anyopaque: *const anyopaque = (@ptrCast(raw.ptr));
                    if (raw_as_anyopaque == ptr) {
                        node.marked = true;
                        return node;
                    }
                },
                .JSArray => |arr| {
                    const arr_values_anyopaque: *const anyopaque = (@ptrCast(arr.values.ptr));
                    if (arr_values_anyopaque == ptr) {
                        node.marked = true;
                        return node;
                    }
                },
                else => {},
            }
            current = node.next;
        }
        return null;
    }

    // Unmark all objects before marking phase
    fn unmarkAll(self: *GarbageCollector) void {
        var obj = self.objects;
        while (obj) |node| {
            node.marked = false;
            switch (node.type) {
                .JSObject => |o| o.marked = false,
                .JSArray => |a| a.marked = false,
                .JSEnv => |e| e.marked = false,
                else => {},
            }
            obj = node.next;
        }
    }

    // Sweep and remove all unmarked objects
    fn sweep(self: *GarbageCollector) void {
        var prev: ?*GCNode = null;
        var obj = self.objects;

        while (obj) |node| {
            if (!node.marked) {
                const unreached = node;
                const next = unreached.next;

                if (prev) |p| {
                    p.next = next;
                } else {
                    self.objects = next;
                }

                self.freeNode(unreached);
                obj = next;
            } else {
                prev = node;
                obj = node.next;
            }
        }
    }

    // Perform full garbage collection
    pub fn collectGarbage(self: *GarbageCollector) !void {
        self.unmarkAll();

        // You'll need to get roots from your interpreter
        // This is a placeholder - replace with actual root collection
        const root_values = [_]Value{};
        self.markRoots(&root_values);

        self.sweep();

        // Adjust threshold to be double current usage
        self.bytes_threshold = self.bytes_allocated * 2;
    }
};

pub const JSEnv = struct {
    values: std.StringHashMap(Value),
    parent: ?*JSEnv,
    marked: bool = false,
};
