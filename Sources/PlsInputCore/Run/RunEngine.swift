import Foundation

extension RunState {
    // MARK: - 动作

    @discardableResult
    public mutating func apply(_ action: RunAction) -> [RunEvent] {
        if phase.isEnded { return [.rejected(.ended)] }
        switch action {
        case .pressKey(let k):
            return pressKey(k)
        case .selectSlot(let i):
            return selectSlot(i)
        case .clearSlot(let i):
            return clearSlot(i)
        case .useItem(let i, let target):
            return useItem(i, target: target)
        case .chooseAddSlot(let kind, let position):
            return chooseAddSlot(kind: kind, position: position)
        case .chooseConvertSlot(let i):
            return chooseConvertSlot(i)
        case .chooseRepairNow(let keyIndex):
            return chooseRepairNow(keyIndex: keyIndex)
        case .end:
            return finish(.playerEnded)
        }
    }

    /// 推进真实经过的时间（秒）。冻结先吃掉时间，剩下的进腐烂时钟。有待选时不推进。
    @discardableResult
    public mutating func tick(_ elapsed: Double) -> [RunEvent] {
        guard phase == .running, pendingChoices.isEmpty, elapsed > 0 else { return [] }
        var events: [RunEvent] = []
        var remaining = elapsed
        if freezeRemaining > 0 {
            let used = min(freezeRemaining, remaining)
            freezeRemaining -= used
            remaining -= used
            if freezeRemaining <= 0 {
                freezeRemaining = 0
                events.append(.freezeEnded)
            }
        }
        if remaining > 0 {
            rotClock += remaining
        }
        if rotClock >= puzzle.runCapSeconds {
            rotClock = puzzle.runCapSeconds
            events += reevaluate()
            events += finish(.timeCap)
            return events
        }
        events += reevaluate()
        return events
    }

    // MARK: - 具体动作

    private mutating func pressKey(_ k: Int) -> [RunEvent] {
        guard pendingChoices.isEmpty else { return [.rejected(.choicePending)] }
        guard keys.indices.contains(k) else { return [.rejected(.invalidIndex)] }
        guard !keys[k].isDead else { return [.rejected(.keyDead)] }

        let target: Int
        if let s = selectedSlot, slots.indices.contains(s), slots[s].kind != .echo {
            target = s
        } else if let s = firstFillableSlot {
            target = s
        } else {
            return [.rejected(.noEmptySlot)]
        }

        var events: [RunEvent] = []
        if phase == .ready {
            phase = .running
            events.append(.started)
        }

        let symbol = keys[k].symbol
        if case .digit(let d) = symbol {
            slots[target].content = .digit(base: d, placedAt: rotClock)
        } else {
            slots[target].content = .op(symbol)
        }
        selectedSlot = nil
        events.append(.slotChanged(target))

        if slots[target].kind != .rotten {
            keys[k].uses -= 1
            events.append(.keyUsed(k, remaining: keys[k].uses))
            if keys[k].isDead {
                events.append(.keyDied(k))
            }
        }

        events += reevaluate()
        events += checkExhausted()
        return events
    }

    private mutating func selectSlot(_ i: Int?) -> [RunEvent] {
        guard pendingChoices.isEmpty else { return [.rejected(.choicePending)] }
        guard let i else {
            selectedSlot = nil
            return []
        }
        guard slots.indices.contains(i) else { return [.rejected(.invalidIndex)] }
        guard slots[i].kind != .echo else { return [.rejected(.echoSlot)] }
        selectedSlot = selectedSlot == i ? nil : i
        return []
    }

    private mutating func clearSlot(_ i: Int) -> [RunEvent] {
        guard pendingChoices.isEmpty else { return [.rejected(.choicePending)] }
        guard slots.indices.contains(i) else { return [.rejected(.invalidIndex)] }
        guard slots[i].kind != .echo else { return [.rejected(.echoSlot)] }
        slots[i].content = .empty
        if selectedSlot == i { selectedSlot = nil }
        var events: [RunEvent] = [.slotChanged(i)]
        events += reevaluate()
        return events
    }

    private mutating func useItem(_ i: Int, target: Int?) -> [RunEvent] {
        guard phase == .running else { return [.rejected(.notRunning)] }
        guard pendingChoices.isEmpty else { return [.rejected(.choicePending)] }
        guard inventory.indices.contains(i) else { return [.rejected(.invalidIndex)] }
        let item = inventory[i]
        switch item {
        case .freeze(let seconds):
            inventory.remove(at: i)
            freezeRemaining += seconds
            return [.itemUsed(item), .freezeStarted(seconds)]
        case .repair(let amount):
            guard let target else { return [.rejected(.needsTarget)] }
            guard keys.indices.contains(target) else { return [.rejected(.invalidIndex)] }
            guard !keys[target].isFull else { return [.rejected(.keyAlreadyFull)] }
            inventory.remove(at: i)
            keys[target].uses = min(keys[target].uses + amount, keys[target].maxUses)
            return [.itemUsed(item)]
        }
    }

    private mutating func chooseAddSlot(kind: SlotKind, position: Int) -> [RunEvent] {
        guard case .addSlot(let choices)? = pendingChoices.first else { return [.rejected(.noChoicePending)] }
        guard choices.contains(kind) else { return [.rejected(.badChoice)] }
        guard position >= 0, position <= slots.count else { return [.rejected(.invalidIndex)] }
        pendingChoices.removeFirst()
        slots.insert(Slot(id: nextSlotID, kind: kind), at: position)
        nextSlotID += 1
        if let s = selectedSlot, s >= position { selectedSlot = s + 1 }
        var events: [RunEvent] = [.slotAdded(position, kind)]
        events += reevaluate()
        return events
    }

    private mutating func chooseConvertSlot(_ i: Int) -> [RunEvent] {
        guard case .convertSlot(let kind)? = pendingChoices.first else { return [.rejected(.noChoicePending)] }
        guard slots.indices.contains(i) else { return [.rejected(.invalidIndex)] }
        pendingChoices.removeFirst()
        // 重定基：保留当前可见数字，让新类型从现在开始计时。
        if let current = rottedDigit(at: i) {
            slots[i].content = .digit(base: current, placedAt: rotClock)
        }
        if kind == .echo {
            slots[i].content = .empty
            if selectedSlot == i { selectedSlot = nil }
        }
        slots[i].kind = kind
        var events: [RunEvent] = [.slotConverted(i, kind)]
        events += reevaluate()
        return events
    }

    private mutating func chooseRepairNow(keyIndex: Int) -> [RunEvent] {
        guard case .repairNow(let amount)? = pendingChoices.first else { return [.rejected(.noChoicePending)] }
        guard keys.indices.contains(keyIndex) else { return [.rejected(.invalidIndex)] }
        guard !keys[keyIndex].isFull else { return [.rejected(.keyAlreadyFull)] }
        pendingChoices.removeFirst()
        keys[keyIndex].uses = min(keys[keyIndex].uses + amount, keys[keyIndex].maxUses)
        var events: [RunEvent] = [.itemUsed(.repair(amount: amount))]
        events += checkExhausted()
        return events
    }

    private mutating func finish(_ reason: EndReason) -> [RunEvent] {
        guard !phase.isEnded else { return [] }
        phase = .ended(reason)
        selectedSlot = nil
        pendingChoices.removeAll()
        return [.ended(reason)]
    }

    private mutating func checkExhausted() -> [RunEvent] {
        guard phase == .running, allKeysDead, !hasRepairAvailable else { return [] }
        return finish(.keysExhausted)
    }

    // MARK: - 求值与阈值

    /// 重新求值：更新显示值、峰值，按序发放跨过的阈值。
    private mutating func reevaluate() -> [RunEvent] {
        var events: [RunEvent] = []
        let value = evaluate()
        if value != currentValue {
            currentValue = value
            events.append(.valueChanged(value))
        }
        guard let value else { return events }
        if value > peak {
            peak = value
            events.append(.newPeak(value))
        }
        while crossedTiers < puzzle.thresholds.count, value >= puzzle.thresholds[crossedTiers] {
            let tier = crossedTiers
            crossedTiers += 1
            let reward = tier < puzzle.rewards.count ? puzzle.rewards[tier] : .repair(amount: 0)
            events.append(.thresholdCrossed(tier: tier, reward: reward))
            events += grant(reward)
        }
        return events
    }

    private mutating func grant(_ reward: Reward) -> [RunEvent] {
        switch reward {
        case .unlockKeys(let defs):
            for def in defs {
                if let existing = keys.firstIndex(where: { $0.symbol == def.symbol }) {
                    keys[existing].uses += def.uses
                    keys[existing].maxUses += def.uses
                } else {
                    let insertAt = keys.firstIndex { $0.symbol.sortOrder > def.symbol.sortOrder } ?? keys.count
                    keys.insert(KeyState(symbol: def.symbol, uses: def.uses), at: insertAt)
                }
            }
            return [.keysUnlocked(defs)]
        case .addSlot(let choices):
            let choice = PendingChoice.addSlot(choices: choices)
            pendingChoices.append(choice)
            return [.choiceRequired(choice)]
        case .convertSlot(let kind):
            let choice = PendingChoice.convertSlot(kind)
            pendingChoices.append(choice)
            return [.choiceRequired(choice)]
        case .repair(let amount):
            if inventory.count < puzzle.inventoryCap {
                inventory.append(.repair(amount: amount))
                return [.itemAdded(.repair(amount: amount))]
            }
            guard hasRepairableKey else { return [.rewardWasted(reward)] }
            let choice = PendingChoice.repairNow(amount: amount)
            pendingChoices.append(choice)
            return [.choiceRequired(choice)]
        case .freeze(let seconds):
            if inventory.count < puzzle.inventoryCap {
                inventory.append(.freeze(seconds: seconds))
                return [.itemAdded(.freeze(seconds: seconds))]
            }
            freezeRemaining += seconds
            return [.itemUsed(.freeze(seconds: seconds)), .freezeStarted(seconds)]
        }
    }
}
