import UIKit
import SwiftUI

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var host: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        model.insertText = { [weak self] text in
            self?.textDocumentProxy.insertText(text)
        }
        model.deleteBackward = { [weak self] in
            self?.textDocumentProxy.deleteBackward()
        }
        model.clearText = { [weak self] in
            self?.clearAll()
        }
        model.nextKeyboard = { [weak self] in
            self?.advanceToNextInputMode()
        }

        let hosting = UIHostingController(rootView: KeyboardView(model: model))
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(hosting)
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        host = hosting

        let height = view.heightAnchor.constraint(equalToConstant: 280)
        height.priority = UILayoutPriority(999)
        height.isActive = true
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // 지구본(키보드 전환) 버튼이 필요한 기기에서만 보이게
        if model.needsGlobe != needsInputModeSwitchKey {
            model.needsGlobe = needsInputModeSwitchKey
        }
        if model.hasFullAccess != hasFullAccess {
            model.hasFullAccess = hasFullAccess
        }
    }

    /// 커서 앞의 글자를 모두 지움
    private func clearAll() {
        var rounds = 0
        while let before = textDocumentProxy.documentContextBeforeInput,
              !before.isEmpty,
              rounds < 30 {
            for _ in 0..<before.count {
                textDocumentProxy.deleteBackward()
            }
            rounds += 1
        }
    }
}
