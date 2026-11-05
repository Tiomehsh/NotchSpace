import Darwin
import Foundation

@_silgen_name("bootstrap_look_up")
private func paneru_bootstrap_look_up(
    _ bp: mach_port_t,
    _ serviceName: UnsafePointer<CChar>,
    _ sp: UnsafeMutablePointer<mach_port_t>
) -> kern_return_t

@_silgen_name("mach_task_self")
private func paneru_mach_task_self() -> mach_port_t

/// Speaks Paneru 0.5.2+'s native `async-mach-ports` + named `MessagePack` protocol directly
/// over `com.github.karinushka.paneru` so NotchSpace can move or focus any arbitrary `window_id`
/// (even unfocused windows or windows parked on inactive virtual workspaces) in <0.1ms.
public enum PaneruMachIPC {
    public static let defaultServiceName = "com.github.karinushka.paneru"

    public static var resolvedServiceName: String {
        if let override = ProcessInfo.processInfo.environment["PANERU_MACH_SERVICE"],
           !override.isEmpty {
            return override
        }
        return defaultServiceName
    }

    /// Sends `Request::WindowSetApply([LayoutOp::MoveToWorkspace { window, workspace, follow }])`.
    /// `workspaceNumber` is 1-based (`1, 2, 3...`), matching Paneru's Lua/WindowSet convention.
    @discardableResult
    public static func moveWindowToWorkspace(
        windowID: Int,
        workspaceNumber: Int,
        follow: Bool
    ) -> Bool {
        guard workspaceNumber >= 1,
              let win32 = Int32(exactly: windowID),
              let ws32 = UInt32(exactly: workspaceNumber) else {
            return false
        }

        var payload: [UInt8] = []
        payload.reserveCapacity(80)

        // {"WindowSetApply": [{"move_to_workspace": {"window": win32, "workspace": ws32, "follow": follow}}]}
        payload.append(0x81) // fixmap(1)
        appendFixStr(&payload, "WindowSetApply")
        payload.append(0x91) // fixarray(1)
        payload.append(0x81) // fixmap(1)
        appendFixStr(&payload, "move_to_workspace")
        payload.append(0x83) // fixmap(3)

        appendFixStr(&payload, "window")
        appendInt32(&payload, win32)

        appendFixStr(&payload, "workspace")
        appendUInt32(&payload, ws32)

        appendFixStr(&payload, "follow")
        payload.append(follow ? 0xc3 : 0xc2)

        return sendFireAndForget(payload: payload)
    }

    /// Sends `Request::WindowSetApply([LayoutOp::Focus(windowID)])`.
    @discardableResult
    public static func focusWindow(windowID: Int) -> Bool {
        guard let win32 = Int32(exactly: windowID) else {
            return false
        }

        var payload: [UInt8] = []
        payload.reserveCapacity(40)

        // {"WindowSetApply": [{"focus": win32}]}
        payload.append(0x81) // fixmap(1)
        appendFixStr(&payload, "WindowSetApply")
        payload.append(0x91) // fixarray(1)
        payload.append(0x81) // fixmap(1)
        appendFixStr(&payload, "focus")
        appendInt32(&payload, win32)

        return sendFireAndForget(payload: payload)
    }

    // MARK: - Mach OOL Framing (`async-mach-ports` 0.3 `OolMsg`, 44 bytes `#pragma pack(4)`)

    private static func sendFireAndForget(payload: [UInt8]) -> Bool {
        let selfTask = paneru_mach_task_self()
        var bootstrapPort: mach_port_t = mach_port_t(MACH_PORT_NULL)
        guard task_get_special_port(selfTask, TASK_BOOTSTRAP_PORT, &bootstrapPort) == KERN_SUCCESS,
              bootstrapPort != mach_port_t(MACH_PORT_NULL) else {
            return false
        }
        defer {
            mach_port_deallocate(selfTask, bootstrapPort)
        }

        var servicePort: mach_port_t = mach_port_t(MACH_PORT_NULL)
        let lookupKR = resolvedServiceName.withCString { cName in
            paneru_bootstrap_look_up(bootstrapPort, cName, &servicePort)
        }
        guard lookupKR == KERN_SUCCESS, servicePort != mach_port_t(MACH_PORT_NULL) else {
            return false
        }
        defer {
            mach_port_deallocate(selfTask, servicePort)
        }

        // Exact 44-byte `OolMsg` layout on 64-bit macOS (`packed(4)`):
        //   0..<24  : mach_msg_header_t
        //   24..<28 : mach_msg_body_t (msgh_descriptor_count = 1)
        //   28..<36 : payload.address (64-bit pointer, unaligned at offset 28)
        //   36      : payload.deallocate (0 = FALSE)
        //   37      : payload.copy (1 = MACH_MSG_VIRTUAL_COPY)
        //   38      : payload.pad1 (0)
        //   39      : payload.type (1 = MACH_MSG_OOL_DESCRIPTOR)
        //   40..<44 : payload.size (UInt32)
        let msgByteCount = 44
        let rawMsg = UnsafeMutableRawPointer.allocate(byteCount: msgByteCount, alignment: 8)
        rawMsg.initializeMemory(as: UInt8.self, repeating: 0, count: msgByteCount)
        defer {
            rawMsg.deallocate()
        }

        let kr: kern_return_t = payload.withUnsafeBufferPointer { payloadBuf in
            let msghBits = UInt32(MACH_MSG_TYPE_COPY_SEND) | UInt32(MACH_MSGH_BITS_COMPLEX)
            rawMsg.storeBytes(of: msghBits, toByteOffset: 0, as: UInt32.self)
            rawMsg.storeBytes(of: UInt32(msgByteCount), toByteOffset: 4, as: UInt32.self)
            rawMsg.storeBytes(of: servicePort, toByteOffset: 8, as: mach_port_t.self)
            rawMsg.storeBytes(of: mach_port_t(MACH_PORT_NULL), toByteOffset: 12, as: mach_port_t.self)
            rawMsg.storeBytes(of: mach_port_t(MACH_PORT_NULL), toByteOffset: 16, as: mach_port_t.self)
            rawMsg.storeBytes(of: Int32(0), toByteOffset: 20, as: Int32.self)

            // mach_msg_body_t.msgh_descriptor_count = 1
            rawMsg.storeBytes(of: UInt32(1), toByteOffset: 24, as: UInt32.self)

            // mach_msg_ool_descriptor_t (unaligned 64-bit pointer at offset 28)
            var addrBits = UInt64(UInt(bitPattern: payloadBuf.baseAddress))
            withUnsafeBytes(of: &addrBits) { src in
                rawMsg.advanced(by: 28).copyMemory(from: src.baseAddress!, byteCount: 8)
            }
            rawMsg.storeBytes(of: UInt8(0), toByteOffset: 36, as: UInt8.self) // deallocate = FALSE
            rawMsg.storeBytes(of: UInt8(MACH_MSG_VIRTUAL_COPY), toByteOffset: 37, as: UInt8.self)
            rawMsg.storeBytes(of: UInt8(0), toByteOffset: 38, as: UInt8.self) // pad1
            rawMsg.storeBytes(of: UInt8(MACH_MSG_OOL_DESCRIPTOR), toByteOffset: 39, as: UInt8.self)
            rawMsg.storeBytes(of: UInt32(payloadBuf.count), toByteOffset: 40, as: UInt32.self)

            let headerPtr = rawMsg.assumingMemoryBound(to: mach_msg_header_t.self)
            return mach_msg(
                headerPtr,
                mach_msg_option_t(MACH_SEND_MSG | MACH_SEND_TIMEOUT),
                mach_msg_size_t(msgByteCount),
                0,
                mach_port_name_t(MACH_PORT_NULL),
                50, // 50ms timeout so UI can never block even if daemon stalls
                mach_port_name_t(MACH_PORT_NULL)
            )
        }

        return kr == KERN_SUCCESS
    }

    // MARK: - Minimal MessagePack Helpers

    private static func appendFixStr(_ out: inout [UInt8], _ s: StaticString) {
        let count = s.utf8CodeUnitCount
        precondition(count <= 31)
        out.append(0xa0 | UInt8(count))
        s.withUTF8Buffer { utf8 in
            out.append(contentsOf: utf8)
        }
    }

    private static func appendInt32(_ out: inout [UInt8], _ value: Int32) {
        out.append(0xd2)
        let be = value.bigEndian
        withUnsafeBytes(of: be) { out.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ out: inout [UInt8], _ value: UInt32) {
        out.append(0xce)
        let be = value.bigEndian
        withUnsafeBytes(of: be) { out.append(contentsOf: $0) }
    }
}
