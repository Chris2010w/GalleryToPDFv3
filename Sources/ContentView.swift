import SwiftUI
import QuickLook

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ContentView: View {
    @StateObject private var vm = JobViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Link:")
            TextField("https://...", text: $vm.url, axis: .vertical)
                .lineLimit(1...2)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Button("Επικόλληση") { vm.paste() }.buttonStyle(.bordered)
                Text(vm.siteHint.0).font(.footnote).foregroundColor(vm.siteHint.1)
            }
            TextField("Όνομα (προαιρετικό)", text: $vm.name)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            if vm.url.lowercased().contains("exhentai") {
                TextField("Cookies ExHentai: ipb_member_id=…; ipb_pass_hash=…; igneous=…", text: $vm.cookie, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote)
            }
            if vm.isVideo {
                Text("Βίντεο → MP4. Ποιότητα:").padding(.top, 4)
                Picker("", selection: $vm.qualityIndex) {
                    ForEach(0..<JobViewModel.qualityLabels.count, id: \.self) { Text(JobViewModel.qualityLabels[$0]).tag($0) }
                }.pickerStyle(.menu)
            } else {
                Text("Αποτέλεσμα:").padding(.top, 4)
                Picker("", selection: $vm.mode) {
                    Text("PDF").tag("pdf"); Text("CBZ").tag("cbz"); Text("Και τα δύο").tag("both")
                }.pickerStyle(.segmented)
                Text("Καθυστέρηση ανά εικόνα:")
                Picker("", selection: $vm.delayIndex) {
                    ForEach(0..<JobViewModel.delayLabels.count, id: \.self) { Text(JobViewModel.delayLabels[$0]).tag($0) }
                }.pickerStyle(.menu)
            }
            HStack {
                Button("Κατέβασε") { vm.start() }.buttonStyle(.borderedProminent).disabled(vm.running).frame(maxWidth: .infinity)
                Button("Ακύρωση") { vm.cancel() }.buttonStyle(.bordered).disabled(!vm.running).frame(maxWidth: .infinity)
                Button("Άνοιγμα") { vm.openLast() }.buttonStyle(.bordered).disabled(vm.running || vm.lastFile == nil).frame(maxWidth: .infinity)
            }
            if let f = vm.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
            HStack {
                Text(vm.percent).bold()
                Spacer()
                Text(vm.counter).bold()
            }
            Text(vm.status).font(.subheadline)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(vm.log)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: vm.log) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .padding(16)
        .onChange(of: scenePhase) { p in if p == .active { vm.autoPasteIfUseful() } }
        .quickLookPreview($vm.previewURL)
        .sheet(isPresented: Binding(get: { vm.shareURL != nil }, set: { if !$0 { vm.shareURL = nil } })) {
            if let u = vm.shareURL { ShareSheet(url: u) }
        }
    }
}
