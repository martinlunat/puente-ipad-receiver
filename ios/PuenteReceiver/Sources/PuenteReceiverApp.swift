import SwiftUI
import Network
import UIKit

@main
struct PuenteReceiverApp: App {
    var body: some Scene { WindowGroup { ReceiverScreen() } }
}

struct ReceiverScreen: View {
    @StateObject private var receiver = USBReceiver()
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let image = receiver.image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(spacing: 10) {
                HStack {
                    Text("puente ↗").font(.title2.bold())
                    Spacer()
                    Text(receiver.status).font(.caption)
                    Button(receiver.listening ? "Detener" : "Conectar USB") {
                        receiver.listening ? receiver.stop() : receiver.start()
                    }.buttonStyle(.borderedProminent).tint(.green)
                }
                if receiver.image == nil {
                    Text("Código de conexión").font(.headline)
                    Text(receiver.pin).font(.system(size: 46, weight: .bold, design: .monospaced))
                    Text("Conectá el cable, confiá en la PC e ingresá este código en Puente para Windows.")
                        .font(.body).multilineTextAlignment(.center)
                }
            }.padding(20).foregroundStyle(.white).background(.black.opacity(0.7))
        }.onDisappear { receiver.stop() }
    }
}

@MainActor
final class USBReceiver: ObservableObject {
    @Published var status = "USB experimental"
    @Published var image: UIImage?
    @Published var pin = String(format: "%06d", Int.random(in: 0...999999))
    @Published var listening = false
    private var listener: NWListener?
    private var client: NWConnection?
    private let queue = DispatchQueue(label: "dev.puente.usb")
    private var generation = UUID()

    func start() {
        stop()
        pin = String(format: "%06d", Int.random(in: 0...999999))
        let session = UUID(); generation = session
        do {
            let parameters = NWParameters.tcp
            // Only loopback: usbmux reaches the app, while Wi-Fi peers cannot connect.
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 48766)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == session else { return }
                    switch state {
                    case .ready: self.listening = true; self.status = "Esperando a la PC por USB"
                    case .failed(let error): self.status = error.localizedDescription; self.stop()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.generation == session, self.client == nil else { connection.cancel(); return }
                    self.client = connection
                    connection.start(queue: self.queue)
                    Task { await self.serve(connection, session: session) }
                }
            }
            listener.start(queue: queue)
            UIApplication.shared.isIdleTimerDisabled = true
        } catch { status = error.localizedDescription }
    }

    func stop() {
        generation = UUID(); client?.cancel(); client = nil; listener?.cancel(); listener = nil
        listening = false; image = nil; status = "Detenido"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func read(_ connection: NWConnection, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: NSError(domain: "Puente", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cable desconectado o transmisión terminada"])) }
            }
        }
    }

    private func sendAck(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data([1]), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func serve(_ connection: NWConnection, session: UUID) async {
        do {
            var hello = Data()
            while hello.count < 32 {
                let byte = try await read(connection, count: 1)
                hello.append(byte)
                if byte.first == 10 { break }
            }
            guard String(data: hello, encoding: .ascii) == "PUENTE/1 \(pin)\n" else {
                throw NSError(domain: "Puente", code: 2, userInfo: [NSLocalizedDescriptionKey: "Código incorrecto"])
            }
            try await sendAck(connection)
            var frames = 0
            while generation == session {
                let header = try await read(connection, count: 4)
                let size = header.reduce(0) { ($0 << 8) | Int($1) }
                guard size > 0, size <= 8 * 1024 * 1024 else { throw NSError(domain: "Puente", code: 3) }
                let data = try await read(connection, count: size)
                guard let frame = UIImage(data: data) else { throw NSError(domain: "Puente", code: 4) }
                guard generation == session else { break }
                image = frame; frames += 1; status = "USB · \(frames) cuadros"
                try await sendAck(connection)
            }
        } catch {
            if generation == session { status = error.localizedDescription; image = nil }
        }
        connection.cancel()
        if generation == session { client = nil }
    }
}
