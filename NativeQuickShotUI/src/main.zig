const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

pub const Model = struct {
    surface: Surface = .hub,
    count: u32 = 0,
    collapsed: bool = false,
    vertical: bool = true,
    expanded: bool = false,
    core_revealed: bool = false,
    core_width: f32 = 0,
    bubble_width: f32 = 0,
    actions_after: bool = false,
    compact: bool = false,
    copied: bool = false,
    position: TrayPosition = .right,
    last_action: Action = .none,
    interaction_hover: Action = .none,
    interaction_pressed: Action = .none,
    tool: AnnotationTool = .select,
    palette_index: u32 = 0,
    stroke_weight: StrokeWeight = .medium,
    filled: bool = false,
    can_undo: bool = false,
    can_redo: bool = false,
    retention: Retention = .week,
    autosave: bool = true,
    high_contrast: bool = false,
    reduce_motion: bool = false,

    pub const view_unbound = .{ "last_action", "high_contrast", "reduce_motion" };

    pub fn coreText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const count_text = if (model.count > 99)
            "99+"
        else
            std.fmt.allocPrint(arena, "{d}", .{model.count}) catch "";
        if (!model.core_revealed) return count_text;
        const action = if (model.collapsed) "Show" else "Hide";
        return std.fmt.allocPrint(arena, "{s} {s}", .{ count_text, action }) catch count_text;
    }

    pub fn coreLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const verb = if (model.collapsed) "Show" else "Hide";
        const noun = if (model.count == 1) "screenshot" else "screenshots";
        return std.fmt.allocPrint(arena, "{s} {d} {s}", .{ verb, model.count, noun }) catch "Toggle screenshots";
    }

    pub fn coreWidthSet(model: *const Model) bool {
        return model.core_width > 0;
    }

    /// Ширина капсулы-подложки. Панель обязана совпадать с фактической шириной
    /// раскрытого ряда: растр рендерится в кадр этой ширины, и всё, что шире,
    /// срезается вместе с правым штрихом обводки.
    pub fn bubbleWidth(model: *const Model) f32 {
        return if (model.bubble_width > 0) model.bubble_width else 800;
    }

    pub fn chevronIcon(model: *const Model) []const u8 {
        if (model.vertical) return if (model.collapsed) "chevron-down" else "chevron-up";
        return if (model.collapsed) "chevron-left" else "chevron-right";
    }

    pub fn thumbnailSurface(model: *const Model) bool {
        return model.surface == .thumbnail;
    }

    pub fn hubBubbleSurface(model: *const Model) bool {
        return model.surface == .hub_bubble;
    }

    pub fn hubCoreBackgroundSurface(model: *const Model) bool {
        return model.surface == .hub_core_background;
    }

    pub fn hubCoreForegroundSurface(model: *const Model) bool {
        return model.surface == .hub_core_foreground;
    }

    pub fn pinnedSurface(model: *const Model) bool {
        return model.surface == .pinned;
    }

    pub fn settingsSurface(model: *const Model) bool {
        return model.surface == .settings;
    }

    pub fn copyIcon(model: *const Model) []const u8 {
        return if (model.copied) "check" else "copy";
    }

    pub fn copyText(model: *const Model) []const u8 {
        return if (model.copied) "Copied" else "Copy";
    }

    pub fn copyLabel(model: *const Model) []const u8 {
        return if (model.copied) "Copied screenshot" else "Copy screenshot";
    }

    pub fn annotationToolbarSurface(model: *const Model) bool {
        return model.surface == .annotation_toolbar;
    }

    pub fn toolSelect(model: *const Model) bool { return model.tool == .select; }
    pub fn toolArrow(model: *const Model) bool { return model.tool == .arrow; }
    pub fn toolBox(model: *const Model) bool { return model.tool == .box; }
    pub fn toolEllipse(model: *const Model) bool { return model.tool == .ellipse; }
    pub fn toolLine(model: *const Model) bool { return model.tool == .line; }
    pub fn toolPen(model: *const Model) bool { return model.tool == .pen; }
    pub fn toolText(model: *const Model) bool { return model.tool == .text; }
    pub fn toolMark(model: *const Model) bool { return model.tool == .mark; }
    pub fn toolStep(model: *const Model) bool { return model.tool == .step; }
    pub fn toolHide(model: *const Model) bool { return model.tool == .hide; }
    pub fn toolBlur(model: *const Model) bool { return model.tool == .blur; }
    pub fn colour0(model: *const Model) bool { return model.palette_index == 0; }
    pub fn colour1(model: *const Model) bool { return model.palette_index == 1; }
    pub fn colour2(model: *const Model) bool { return model.palette_index == 2; }
    pub fn colour3(model: *const Model) bool { return model.palette_index == 3; }
    pub fn colour4(model: *const Model) bool { return model.palette_index == 4; }
    pub fn colour5(model: *const Model) bool { return model.palette_index == 5; }
    pub fn weightThin(model: *const Model) bool { return model.stroke_weight == .thin; }
    pub fn weightMedium(model: *const Model) bool { return model.stroke_weight == .medium; }
    pub fn weightThick(model: *const Model) bool { return model.stroke_weight == .thick; }
    pub fn fillOn(model: *const Model) bool { return model.filled; }
    pub fn fillOff(model: *const Model) bool { return !model.filled; }

    pub fn canUndo(model: *const Model) bool { return model.can_undo; }
    pub fn canRedo(model: *const Model) bool { return model.can_redo; }

    pub fn retentionDay(model: *const Model) bool { return model.retention == .day; }
    pub fn retentionWeek(model: *const Model) bool { return model.retention == .week; }
    pub fn retentionMonth(model: *const Model) bool { return model.retention == .month; }
    pub fn retentionForever(model: *const Model) bool { return model.retention == .forever; }
    pub fn autosaveEnabled(model: *const Model) bool { return model.autosave; }
    pub fn autosaveDisabled(model: *const Model) bool { return !model.autosave; }

    pub fn positionLeft(model: *const Model) bool { return model.position == .left; }
    pub fn positionRight(model: *const Model) bool { return model.position == .right; }
    pub fn positionBottom(model: *const Model) bool { return model.position == .bottom; }
    pub fn positionTop(model: *const Model) bool { return model.position == .top; }
};

pub const Surface = enum {
    hub,
    hub_bubble,
    hub_core_background,
    hub_core_foreground,
    thumbnail,
    pinned,
    settings,
    annotation_toolbar,
};

pub const TrayPosition = enum {
    left,
    right,
    bottom,
    top,
};

pub const StrokeWeight = enum {
    thin,
    medium,
    thick,
};

pub const AnnotationTool = enum {
    select,
    arrow,
    box,
    ellipse,
    line,
    pen,
    text,
    mark,
    step,
    hide,
    blur,
};

pub const Retention = enum {
    day,
    week,
    month,
    forever,
};

pub const Action = enum {
    none,
    toggle,
    delete,
    save_as,
    copy_all,
    copy,
    dismiss,
    position_left,
    position_right,
    position_bottom,
    position_top,
    retention_day,
    retention_week,
    retention_month,
    retention_forever,
    autosave_on,
    autosave_off,
    open_folder,
    tool_select,
    tool_arrow,
    tool_box,
    tool_ellipse,
    tool_line,
    tool_pen,
    tool_text,
    tool_mark,
    tool_step,
    tool_hide,
    tool_blur,
    editor_undo,
    editor_redo,
    editor_save,
    editor_copy,
    editor_close,
    editor_scan,
    colour_0,
    colour_1,
    colour_2,
    colour_3,
    colour_4,
    colour_5,
    weight_thin,
    weight_medium,
    weight_thick,
    fill_on,
    fill_off,
};

pub const Metric = enum(c_int) {
    control_height,
    control_radius,
    control_inset,
    icon_side,
    icon_gap,
    button_font_size,
    group_gap,
    shell_inset,
    bubble_radius,
    animation_duration_ms,
    reduced_animation_duration_ms,
};

pub const Msg = union(enum) {
    toggle,
    delete,
    save_as,
    copy_all,
    copy,
    dismiss,
    position_left,
    position_right,
    position_bottom,
    position_top,
    retention_day,
    retention_week,
    retention_month,
    retention_forever,
    autosave_on,
    autosave_off,
    open_folder,
    tool_select,
    tool_arrow,
    tool_box,
    tool_ellipse,
    tool_line,
    tool_pen,
    tool_text,
    tool_mark,
    tool_step,
    tool_hide,
    tool_blur,
    editor_undo,
    editor_redo,
    editor_save,
    editor_copy,
    editor_close,
    editor_scan,
    colour_0,
    colour_1,
    colour_2,
    colour_3,
    colour_4,
    colour_5,
    weight_thin,
    weight_medium,
    weight_thick,
    fill_on,
    fill_off,
    set_count: u32,
    set_collapsed: bool,
    set_vertical: bool,
    set_expanded: bool,
    set_core_revealed: bool,
    set_core_width: f32,
    set_bubble_width: f32,
    set_actions_after: bool,
    set_surface: Surface,
    set_compact: bool,
    set_copied: bool,
    set_position: TrayPosition,
    set_retention: Retention,
    set_tool: AnnotationTool,
    set_can_undo: bool,
    set_colour: u32,
    set_weight: StrokeWeight,
    set_fill: bool,
    set_can_redo: bool,
    set_autosave: bool,
    set_interaction_hover: Action,
    set_interaction_pressed: Action,
};

const App = native_sdk.UiApp(Model, Msg);

const command_count_prefix = "hub.count:";
const command_collapsed_prefix = "hub.collapsed:";
const command_vertical_prefix = "hub.vertical:";
const command_expanded_prefix = "hub.expanded:";
const command_core_revealed_prefix = "hub.core_revealed:";
const command_core_width_prefix = "hub.core_width:";
const command_bubble_width_prefix = "hub.bubble_width:";
const command_actions_after_prefix = "hub.actions_after:";
const command_surface_prefix = "surface:";
const command_compact_prefix = "control.compact:";
const command_copied_prefix = "control.copied:";
const command_position_prefix = "settings.position:";
const command_retention_prefix = "settings.retention:";
const command_tool_prefix = "editor.tool:";
const command_can_undo_prefix = "editor.can_undo:";
const command_colour_prefix = "editor.colour:";
const command_weight_prefix = "editor.weight:";
const command_fill_prefix = "editor.fill:";
const command_can_redo_prefix = "editor.can_redo:";
const command_autosave_prefix = "settings.autosave:";
const command_interaction_hover_prefix = "ui.hover:";
const command_interaction_pressed_prefix = "ui.pressed:";

pub const hub_markup = @embedFile("hub.native");
pub const CompiledHubView = canvas.CompiledMarkupView(Model, Msg, hub_markup);

pub fn initModel() Model {
    return .{};
}

pub fn mobileOptions() App.Options {
    return .{
        .name = "quickshot-native-ui",
        .scene = native_sdk.embed.mobile_shell_scene,
        .canvas_label = native_sdk.embed.mobile_gpu_surface_label,
        .tokens_fn = designTokens,
        .update = update,
        .view = view,
        .on_command = onCommand,
    };
}

fn designTokens(model: *const Model) canvas.DesignTokens {
    var tokens = canvas.DesignTokens.theme(.{
        .pack = .house,
        .color_scheme = .dark,
        .contrast = if (model.high_contrast) .high else .standard,
        .reduce_motion = model.reduce_motion,
    });
    if (model.surface == .hub or model.surface == .hub_bubble or model.surface == .hub_core_background or model.surface == .hub_core_foreground or model.surface == .thumbnail or model.surface == .pinned) {
        tokens.colors.background = canvas.Color.rgba8(0, 0, 0, 0);
    }
    return tokens;
}

fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .toggle => {
            model.collapsed = !model.collapsed;
            model.last_action = .toggle;
        },
        .delete => model.last_action = .delete,
        .save_as => model.last_action = .save_as,
        .copy_all => model.last_action = .copy_all,
        .copy => model.last_action = .copy,
        .dismiss => model.last_action = .dismiss,
        .position_left => {
            model.position = .left;
            model.last_action = .position_left;
        },
        .position_right => {
            model.position = .right;
            model.last_action = .position_right;
        },
        .position_bottom => {
            model.position = .bottom;
            model.last_action = .position_bottom;
        },
        .position_top => {
            model.position = .top;
            model.last_action = .position_top;
        },
        .retention_day => {
            model.retention = .day;
            model.last_action = .retention_day;
        },
        .retention_week => {
            model.retention = .week;
            model.last_action = .retention_week;
        },
        .retention_month => {
            model.retention = .month;
            model.last_action = .retention_month;
        },
        .retention_forever => {
            model.retention = .forever;
            model.last_action = .retention_forever;
        },
        .autosave_on => {
            model.autosave = true;
            model.last_action = .autosave_on;
        },
        .autosave_off => {
            model.autosave = false;
            model.last_action = .autosave_off;
        },
        .open_folder => model.last_action = .open_folder,
        .tool_select => { model.tool = .select; model.last_action = .tool_select; },
        .tool_arrow => { model.tool = .arrow; model.last_action = .tool_arrow; },
        .tool_box => { model.tool = .box; model.last_action = .tool_box; },
        .tool_ellipse => { model.tool = .ellipse; model.last_action = .tool_ellipse; },
        .tool_line => { model.tool = .line; model.last_action = .tool_line; },
        .tool_pen => { model.tool = .pen; model.last_action = .tool_pen; },
        .tool_text => { model.tool = .text; model.last_action = .tool_text; },
        .tool_mark => { model.tool = .mark; model.last_action = .tool_mark; },
        .tool_step => { model.tool = .step; model.last_action = .tool_step; },
        .tool_hide => { model.tool = .hide; model.last_action = .tool_hide; },
        .tool_blur => { model.tool = .blur; model.last_action = .tool_blur; },
        .editor_undo => model.last_action = .editor_undo,
        .editor_redo => model.last_action = .editor_redo,
        .editor_save => model.last_action = .editor_save,
        .editor_copy => model.last_action = .editor_copy,
        .editor_close => model.last_action = .editor_close,
        .editor_scan => model.last_action = .editor_scan,
        .colour_0 => { model.palette_index = 0; model.last_action = .colour_0; },
        .colour_1 => { model.palette_index = 1; model.last_action = .colour_1; },
        .colour_2 => { model.palette_index = 2; model.last_action = .colour_2; },
        .colour_3 => { model.palette_index = 3; model.last_action = .colour_3; },
        .colour_4 => { model.palette_index = 4; model.last_action = .colour_4; },
        .colour_5 => { model.palette_index = 5; model.last_action = .colour_5; },
        .weight_thin => { model.stroke_weight = .thin; model.last_action = .weight_thin; },
        .weight_medium => { model.stroke_weight = .medium; model.last_action = .weight_medium; },
        .weight_thick => { model.stroke_weight = .thick; model.last_action = .weight_thick; },
        .fill_on => { model.filled = true; model.last_action = .fill_on; },
        .fill_off => { model.filled = false; model.last_action = .fill_off; },


        .set_count => |count| model.count = count,
        .set_collapsed => |collapsed| model.collapsed = collapsed,
        .set_vertical => |vertical| model.vertical = vertical,
        .set_expanded => |expanded| model.expanded = expanded,
        .set_core_revealed => |revealed| model.core_revealed = revealed,
        .set_core_width => |width| model.core_width = @max(0, width),
        .set_bubble_width => |width| model.bubble_width = @max(0, width),
        .set_actions_after => |actions_after| model.actions_after = actions_after,
        .set_surface => |surface| model.surface = surface,
        .set_compact => |compact| model.compact = compact,
        .set_copied => |copied| model.copied = copied,
        .set_position => |position| model.position = position,
        .set_retention => |retention| model.retention = retention,
        .set_tool => |tool| model.tool = tool,
        .set_can_undo => |value| model.can_undo = value,
        .set_colour => |value| model.palette_index = value,
        .set_weight => |value| model.stroke_weight = value,
        .set_fill => |value| model.filled = value,
        .set_can_redo => |value| model.can_redo = value,
        .set_autosave => |enabled| model.autosave = enabled,
        .set_interaction_hover => |action| model.interaction_hover = action,
        .set_interaction_pressed => |action| model.interaction_pressed = action,
    }
}

fn onCommand(name: []const u8) ?Msg {
    if (std.mem.startsWith(u8, name, command_count_prefix)) {
        const raw = name[command_count_prefix.len..];
        const value = std.fmt.parseUnsigned(u32, raw, 10) catch return null;
        return .{ .set_count = value };
    }
    if (std.mem.startsWith(u8, name, command_collapsed_prefix)) {
        return .{ .set_collapsed = parseBool(name[command_collapsed_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_vertical_prefix)) {
        return .{ .set_vertical = parseBool(name[command_vertical_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_expanded_prefix)) {
        return .{ .set_expanded = parseBool(name[command_expanded_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_core_revealed_prefix)) {
        return .{ .set_core_revealed = parseBool(name[command_core_revealed_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_core_width_prefix)) {
        const raw = name[command_core_width_prefix.len..];
        return .{ .set_core_width = std.fmt.parseFloat(f32, raw) catch return null };
    }
    if (std.mem.startsWith(u8, name, command_bubble_width_prefix)) {
        const raw = name[command_bubble_width_prefix.len..];
        return .{ .set_bubble_width = std.fmt.parseFloat(f32, raw) catch return null };
    }
    if (std.mem.startsWith(u8, name, command_actions_after_prefix)) {
        return .{ .set_actions_after = parseBool(name[command_actions_after_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_surface_prefix)) {
        const raw = name[command_surface_prefix.len..];
        if (std.mem.eql(u8, raw, "hub")) return .{ .set_surface = .hub };
        if (std.mem.eql(u8, raw, "hub_bubble")) return .{ .set_surface = .hub_bubble };
        if (std.mem.eql(u8, raw, "hub_core_background")) return .{ .set_surface = .hub_core_background };
        if (std.mem.eql(u8, raw, "hub_core_foreground")) return .{ .set_surface = .hub_core_foreground };
        if (std.mem.eql(u8, raw, "thumbnail")) return .{ .set_surface = .thumbnail };
        if (std.mem.eql(u8, raw, "pinned")) return .{ .set_surface = .pinned };
        if (std.mem.eql(u8, raw, "settings")) return .{ .set_surface = .settings };
        if (std.mem.eql(u8, raw, "annotation_toolbar")) return .{ .set_surface = .annotation_toolbar };
        return null;
    }
    if (std.mem.startsWith(u8, name, command_compact_prefix)) {
        return .{ .set_compact = parseBool(name[command_compact_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_copied_prefix)) {
        return .{ .set_copied = parseBool(name[command_copied_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_position_prefix)) {
        return .{ .set_position = parsePosition(name[command_position_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_retention_prefix)) {
        return .{ .set_retention = parseRetention(name[command_retention_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_tool_prefix)) {
        return .{ .set_tool = parseTool(name[command_tool_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_can_undo_prefix)) {
        return .{ .set_can_undo = parseBool(name[command_can_undo_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_colour_prefix)) {
        const raw = name[command_colour_prefix.len..];
        return .{ .set_colour = std.fmt.parseUnsigned(u32, raw, 10) catch return null };
    }
    if (std.mem.startsWith(u8, name, command_weight_prefix)) {
        return .{ .set_weight = parseWeight(name[command_weight_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_fill_prefix)) {
        return .{ .set_fill = parseBool(name[command_fill_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_can_redo_prefix)) {
        return .{ .set_can_redo = parseBool(name[command_can_redo_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_autosave_prefix)) {
        return .{ .set_autosave = parseBool(name[command_autosave_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_interaction_hover_prefix)) {
        return .{ .set_interaction_hover = parseAction(name[command_interaction_hover_prefix.len..]) orelse return null };
    }
    if (std.mem.startsWith(u8, name, command_interaction_pressed_prefix)) {
        return .{ .set_interaction_pressed = parseAction(name[command_interaction_pressed_prefix.len..]) orelse return null };
    }
    return null;
}

fn parseBool(raw: []const u8) ?bool {
    if (std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "true")) return true;
    if (std.mem.eql(u8, raw, "0") or std.mem.eql(u8, raw, "false")) return false;
    return null;
}

fn parsePosition(raw: []const u8) ?TrayPosition {
    if (std.mem.eql(u8, raw, "left")) return .left;
    if (std.mem.eql(u8, raw, "right")) return .right;
    if (std.mem.eql(u8, raw, "bottom")) return .bottom;
    if (std.mem.eql(u8, raw, "top")) return .top;
    return null;
}

fn parseWeight(raw: []const u8) ?StrokeWeight {
    if (std.mem.eql(u8, raw, "thin")) return .thin;
    if (std.mem.eql(u8, raw, "medium")) return .medium;
    if (std.mem.eql(u8, raw, "thick")) return .thick;
    return null;
}

fn parseTool(raw: []const u8) ?AnnotationTool {
    if (std.mem.eql(u8, raw, "select")) return .select;
    if (std.mem.eql(u8, raw, "arrow")) return .arrow;
    if (std.mem.eql(u8, raw, "box")) return .box;
    if (std.mem.eql(u8, raw, "ellipse")) return .ellipse;
    if (std.mem.eql(u8, raw, "line")) return .line;
    if (std.mem.eql(u8, raw, "pen")) return .pen;
    if (std.mem.eql(u8, raw, "text")) return .text;
    if (std.mem.eql(u8, raw, "mark")) return .mark;
    if (std.mem.eql(u8, raw, "step")) return .step;
    if (std.mem.eql(u8, raw, "hide")) return .hide;
    if (std.mem.eql(u8, raw, "blur")) return .blur;
    return null;
}

fn parseRetention(raw: []const u8) ?Retention {
    if (std.mem.eql(u8, raw, "day")) return .day;
    if (std.mem.eql(u8, raw, "week")) return .week;
    if (std.mem.eql(u8, raw, "month")) return .month;
    if (std.mem.eql(u8, raw, "forever")) return .forever;
    return null;
}

fn parseAction(raw: []const u8) ?Action {
    const value = std.fmt.parseUnsigned(u8, raw, 10) catch return null;
    if (value > @intFromEnum(Action.fill_off)) return null;
    return @enumFromInt(value);
}

fn view(ui: *App.Ui, model: *const Model) App.Ui.Node {
    const compiled = CompiledHubView.build(ui, model);
    return applyInteractionState(ui, compiled, model);
}

fn applyInteractionState(ui: *App.Ui, node: App.Ui.Node, model: *const Model) App.Ui.Node {
    var result = node;
    if (result.on_press) |msg| {
        const action = actionForMessage(msg);
        result.widget.state.hovered = action != .none and action == model.interaction_hover;
        result.widget.state.pressed = action != .none and action == model.interaction_pressed;
    }
    if (node.nodes.len > 0) {
        const children = ui.arena.alloc(App.Ui.Node, node.nodes.len) catch {
            ui.failed = true;
            return result;
        };
        for (node.nodes, 0..) |child, index| {
            children[index] = applyInteractionState(ui, child, model);
        }
        result.nodes = children;
    }
    return result;
}

fn actionForMessage(msg: Msg) Action {
    return switch (msg) {
        .toggle => .toggle,
        .delete => .delete,
        .save_as => .save_as,
        .copy_all => .copy_all,
        .copy => .copy,
        .dismiss => .dismiss,
        .position_left => .position_left,
        .position_right => .position_right,
        .position_bottom => .position_bottom,
        .position_top => .position_top,
        .retention_day => .retention_day,
        .retention_week => .retention_week,
        .retention_month => .retention_month,
        .retention_forever => .retention_forever,
        .autosave_on => .autosave_on,
        .autosave_off => .autosave_off,
        .open_folder => .open_folder,
        .tool_select => .tool_select,
        .tool_arrow => .tool_arrow,
        .tool_box => .tool_box,
        .tool_ellipse => .tool_ellipse,
        .tool_line => .tool_line,
        .tool_pen => .tool_pen,
        .tool_text => .tool_text,
        .tool_mark => .tool_mark,
        .tool_step => .tool_step,
        .tool_hide => .tool_hide,
        .tool_blur => .tool_blur,
        .editor_undo => .editor_undo,
        .editor_redo => .editor_redo,
        .editor_save => .editor_save,
        .editor_copy => .editor_copy,
        .editor_close => .editor_close,
        .editor_scan => .editor_scan,
        .colour_0 => .colour_0,
        .colour_1 => .colour_1,
        .colour_2 => .colour_2,
        .colour_3 => .colour_3,
        .colour_4 => .colour_4,
        .colour_5 => .colour_5,
        .weight_thin => .weight_thin,
        .weight_medium => .weight_medium,
        .weight_thick => .weight_thick,
        .fill_on => .fill_on,
        .fill_off => .fill_off,


        else => .none,
    };
}

/// AppKit hosts the windows, while Native SDK remains the interaction and
/// token authority. The mobile ABI has touch but no desktop hover event, so
/// this narrow bridge forwards a real pointer-move into the same runtime path
/// used by the desktop backend.
pub export fn quickshot_native_ui_pointer_move(raw_app: ?*anyopaque, x: f32, y: f32) callconv(.c) void {
    const pointer = raw_app orelse return;
    const Host = native_sdk.embed.UiAppHost(@This());
    const host: *Host = @ptrCast(@alignCast(pointer));
    const now = native_sdk.nowNanoseconds();
    host.embedded.runtime.dispatchPlatformEvent(host.embedded.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = native_sdk.embed.mobile_gpu_surface_label,
        .kind = .pointer_move,
        .timestamp_ns = if (now > 0) @intCast(now) else 0,
        .pointer_id = 1,
        .x = x,
        .y = y,
    } }) catch |err| {
        host.last_error = err;
    };
}

/// Product callbacks are read after Native SDK has completed its own pointer
/// dispatch. Taking the action clears it, preventing a previous command from
/// leaking into a later click.
pub export fn quickshot_native_ui_take_action(raw_app: ?*anyopaque) callconv(.c) c_int {
    const pointer = raw_app orelse return @intFromEnum(Action.none);
    const Host = native_sdk.embed.UiAppHost(@This());
    const host: *Host = @ptrCast(@alignCast(pointer));
    const action = host.ui.model.last_action;
    host.ui.model.last_action = .none;
    return @intFromEnum(action);
}

pub export fn quickshot_native_ui_set_appearance(raw_app: ?*anyopaque, dark: c_int, high_contrast: c_int, reduce_motion: c_int) callconv(.c) void {
    const pointer = raw_app orelse return;
    const Host = native_sdk.embed.UiAppHost(@This());
    const host: *Host = @ptrCast(@alignCast(pointer));
    host.ui.model.high_contrast = high_contrast != 0;
    host.ui.model.reduce_motion = reduce_motion != 0;
    host.embedded.runtime.dispatchPlatformEvent(host.embedded.app, .{ .appearance_changed = .{
        .color_scheme = if (dark != 0) .dark else .light,
        .high_contrast = high_contrast != 0,
        .reduce_motion = reduce_motion != 0,
    } }) catch |err| {
        host.last_error = err;
    };
}

/// Swift consumes these values instead of maintaining a second, drifting copy
/// of the House register. The returned values are scheme-independent tokens.
pub export fn quickshot_native_ui_metric(raw_metric: c_int) callconv(.c) f32 {
    if (raw_metric < @intFromEnum(Metric.control_height) or
        raw_metric > @intFromEnum(Metric.reduced_animation_duration_ms)) return 0;
    const metric: Metric = @enumFromInt(raw_metric);
    const tokens = canvas.DesignTokens.theme(.{ .pack = .house, .color_scheme = .dark });
    return switch (metric) {
        .control_height => tokens.metrics.control_height_sm,
        .control_radius => tokens.radius.md,
        .control_inset => tokens.metrics.button_inset_sm,
        .icon_side => tokens.typography.button_size + tokens.metrics.icon_text_step,
        .icon_gap => tokens.metrics.button_icon_gap,
        .button_font_size => tokens.typography.button_size,
        .group_gap => tokens.spacing.sm,
        .shell_inset => tokens.radius.xl - tokens.radius.md,
        .bubble_radius => tokens.radius.xl,
        .animation_duration_ms => @floatFromInt(tokens.motion.fast_ms),
        .reduced_animation_duration_ms => @floatFromInt(canvas.DesignTokens.theme(.{
            .pack = .house,
            .color_scheme = .dark,
            .reduce_motion = true,
        }).motion.fast_ms),
    };
}
