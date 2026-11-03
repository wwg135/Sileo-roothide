//
//  TabBar.swift
//  Sileo
//
//  Created by CoolStar on 7/27/19.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import Foundation

class TabBar: UITabBar {
    var onLayout: (() -> Void)?
    private var didScheduleRelayout = false

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
        if !didScheduleRelayout, onLayout != nil {
            didScheduleRelayout = true
            // Item buttons settle after the first layout pass at launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.onLayout?()
            }
        }
    }


    override var traitCollection: UITraitCollection {
        if UIDevice.current.userInterfaceIdiom == .phone {
            return super.traitCollection
        }
        if UIApplication.shared.statusBarOrientation.isLandscape && self.bounds.width >= 400 {
            return super.traitCollection
        }
        return UITraitCollection(traitsFrom: [super.traitCollection, UITraitCollection(horizontalSizeClass: .compact)])
    }
}
