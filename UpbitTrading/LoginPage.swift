import SwiftUI

struct LoginPage: View {
    @Binding var isLoggedIn: Bool
    @State private var isChecking: Bool = true
    @State private var showSettings: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 20) {
                Spacer()
                
                Image(systemName: "lock.shield")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: min(geometry.size.width * 0.3, 150), height: min(geometry.size.width * 0.3, 150))
                    .foregroundColor(.blue)
                
                if isChecking {
                    ProgressView("Verifying API Keys...")
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    Text("API Keys Not Found")
                        .font(.headline)
                        .foregroundColor(.red)
                    
                    Button(action: checkCredentials) {
                        Text("Try Again")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    
                    Button(action: { showSettings = true }) {
                        Text("Open Settings")
                            .padding()
                            .background(Color.gray)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
                
                Spacer()
            }
            .padding()
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear(perform: checkCredentials)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
    
    private func checkCredentials() {
        isChecking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if KeyManager.shared.areKeysAvailable() {
                isLoggedIn = true
            } else {
                isChecking = false
            }
        }
    }
}

struct SettingsView: View {
    @State private var accessKey: String = ""
    @State private var secretKey: String = ""
    
    var body: some View {
        Form {
            Section(header: Text("API Keys")) {
                TextField("Access Key", text: $accessKey)
                SecureField("Secret Key", text: $secretKey)
            }
            
            Button("Save") {
                // Here you would typically save these keys securely
                // For this example, we'll just print them
                print("Access Key: \(accessKey)")
                print("Secret Key: \(secretKey)")
            }
        }
        .padding()
    }
}

struct LoginPage_Previews: PreviewProvider {
    static var previews: some View {
        LoginPage(isLoggedIn: .constant(false))
    }
}
