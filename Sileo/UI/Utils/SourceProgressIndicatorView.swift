//
//  SourceProgressIndicatorView.swift
//  Sileo
//
//  Created by CoolStar on 7/27/19.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import Foundation

class SourceProgressIndicatorView: UIView {
    private let barView: UIView
    private var barWidthConstraint: NSLayoutConstraint?
    private let percentLabel = UILabel()
    private let percentLabelSize = CGSize(width: 36, height: 12)

    /// Shows the percentage above the head of the bar.
    public var showsPercentage: Bool = false {
        didSet { updatePercentLabel() }
    }
    
    override init(frame: CGRect) {
        barView = UIView()
        
        super.init(frame: frame)
        
        barView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(barView)
        barView.topAnchor.constraint(equalTo: self.topAnchor).isActive = true
        barView.bottomAnchor.constraint(equalTo: self.bottomAnchor).isActive = true
        barView.leadingAnchor.constraint(equalTo: self.leadingAnchor).isActive = true

        percentLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        percentLabel.textAlignment = .center
        percentLabel.isHidden = true
        self.addSubview(percentLabel)
        self.clipsToBounds = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePercentLabel()
    }

    private func updatePercentLabel() {
        let value = max(0, min(1, progress))
        percentLabel.isHidden = !showsPercentage || value <= 0
        guard !percentLabel.isHidden else { return }
        percentLabel.textColor = self.tintColor
        percentLabel.text = "\(Int(value * 100))%"
        let headX = bounds.width * value - percentLabelSize.width / 2
        let x = max(0, min(bounds.width - percentLabelSize.width, headX))
        percentLabel.frame = CGRect(origin: CGPoint(x: x, y: -percentLabelSize.height - 1), size: percentLabelSize)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func tintColorDidChange() {
        super.tintColorDidChange()
        barView.backgroundColor = self.tintColor
        percentLabel.textColor = self.tintColor
    }
    
    public var progress: CGFloat = 0 {
        didSet {
            self.updateProgress()
        }
    }
    
    func updateProgress() {
        barWidthConstraint?.isActive = false
        barWidthConstraint = barView.widthAnchor.constraint(equalTo: self.widthAnchor, multiplier: self.progress)
        barWidthConstraint?.isActive = true
        updatePercentLabel()
    }
}
