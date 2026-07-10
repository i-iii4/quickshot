import Foundation

let nativeSDKWidgetRoleButton: Int32 = 4
let nativeSDKWidgetActionPressFlag: UInt32 = 1 << 1
let nativeSDKWidgetHoveredFlag: UInt32 = 1 << 1
let nativeSDKWidgetPressedFlag: UInt32 = 1 << 2

enum NativeSDKMetric: Int32 {
    case controlHeight
    case controlRadius
    case controlInset
    case iconSide
    case iconGap
    case buttonFontSize
    case groupGap
    case shellInset
    case bubbleRadius
    case animationDurationMilliseconds
    case reducedAnimationDurationMilliseconds
}

struct NativeSDKCanvasPixels {
    var width: UInt
    var height: UInt
    var byte_len: UInt
}

struct NativeSDKWidgetSemantics {
    var id: UInt64
    var parent_id: UInt64
    var role: Int32
    var flags: UInt32
    var actions: UInt32
    var x: Float
    var y: Float
    var width: Float
    var height: Float
    var value: Float
    var has_value: Int32
    var label: UnsafePointer<CChar>?
    var label_len: UInt
    var text: UnsafePointer<CChar>?
    var text_len: UInt
    var placeholder: UnsafePointer<CChar>?
    var placeholder_len: UInt
    var text_selection_start: Int
    var text_selection_end: Int
    var text_composition_start: Int
    var text_composition_end: Int
    var grid_row_index: Int
    var grid_column_index: Int
    var grid_row_count: Int
    var grid_column_count: Int
    var list_item_index: Int
    var list_item_count: Int
    var scroll_offset: Float
    var scroll_viewport_extent: Float
    var scroll_content_extent: Float
    var has_scroll: Int32
}

@_silgen_name("native_sdk_app_create")
func native_sdk_app_create() -> UnsafeMutableRawPointer?

@_silgen_name("native_sdk_app_destroy")
func native_sdk_app_destroy(_ app: UnsafeMutableRawPointer?)

@_silgen_name("native_sdk_app_start")
func native_sdk_app_start(_ app: UnsafeMutableRawPointer?)

@_silgen_name("native_sdk_app_activate")
func native_sdk_app_activate(_ app: UnsafeMutableRawPointer?)

@_silgen_name("native_sdk_app_stop")
func native_sdk_app_stop(_ app: UnsafeMutableRawPointer?)

@_silgen_name("native_sdk_app_resize")
func native_sdk_app_resize(_ app: UnsafeMutableRawPointer?, _ width: Float, _ height: Float, _ scale: Float, _ surface: UnsafeMutableRawPointer?)

@_silgen_name("native_sdk_app_frame")
func native_sdk_app_frame(_ app: UnsafeMutableRawPointer?)

@_silgen_name("native_sdk_app_command")
func native_sdk_app_command(_ app: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?, _ len: UInt)

@_silgen_name("native_sdk_app_last_error_name")
func native_sdk_app_last_error_name(_ app: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?

@_silgen_name("native_sdk_app_widget_semantics_count")
func native_sdk_app_widget_semantics_count(_ app: UnsafeMutableRawPointer?) -> UInt

@_silgen_name("native_sdk_app_widget_semantics_at")
func native_sdk_app_widget_semantics_at(_ app: UnsafeMutableRawPointer?, _ index: UInt, _ out: UnsafeMutablePointer<NativeSDKWidgetSemantics>?) -> Int32

@_silgen_name("native_sdk_app_touch")
func native_sdk_app_touch(_ app: UnsafeMutableRawPointer?, _ id: UInt64, _ phase: Int32, _ x: Float, _ y: Float, _ pressure: Float)

@_silgen_name("quickshot_native_ui_pointer_move")
func quickshot_native_ui_pointer_move(_ app: UnsafeMutableRawPointer?, _ x: Float, _ y: Float)

@_silgen_name("quickshot_native_ui_take_action")
func quickshot_native_ui_take_action(_ app: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("quickshot_native_ui_set_appearance")
func quickshot_native_ui_set_appearance(_ app: UnsafeMutableRawPointer?, _ dark: Int32, _ highContrast: Int32, _ reduceMotion: Int32)

@_silgen_name("quickshot_native_ui_metric")
func quickshot_native_ui_metric(_ metric: Int32) -> Float

@_silgen_name("native_sdk_app_render_pixel_size")
func native_sdk_app_render_pixel_size(_ app: UnsafeMutableRawPointer?, _ scale: Float, _ out: UnsafeMutablePointer<NativeSDKCanvasPixels>?) -> Int32

@_silgen_name("native_sdk_app_render_pixels")
func native_sdk_app_render_pixels(_ app: UnsafeMutableRawPointer?, _ scale: Float, _ pixels: UnsafeMutablePointer<UInt8>?, _ pixels_len: UInt, _ out: UnsafeMutablePointer<NativeSDKCanvasPixels>?) -> Int32

func nativeSDKString(_ pointer: UnsafePointer<CChar>?, length: UInt) -> String {
    guard let pointer, length > 0 else { return "" }
    let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(length))
    return String(decoding: bytes, as: UTF8.self)
}
