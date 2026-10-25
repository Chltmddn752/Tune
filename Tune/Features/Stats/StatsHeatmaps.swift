import SwiftUI

/// 히트맵 칸 색 (0 = 안 들음, 1~4 = 사분위 단계)
enum HeatColor {
    static func color(_ level: Int) -> Color {
        switch level {
        case 0: Color(.tertiarySystemFill)
        case 1: Color.tuneAccent.opacity(0.3)
        case 2: Color.tuneAccent.opacity(0.52)
        case 3: Color.tuneAccent.opacity(0.76)
        default: Color.tuneAccent
        }
    }
}

struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("적음")
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(HeatColor.color(level))
                    .frame(width: 11, height: 11)
            }
            Text("많음")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// GitHub 잔디처럼 최근 1년을 주 단위 칸으로 (세로 = 월~일)
struct YearHeatmap: View {
    let counts: [Int: Int]
    var today: Int = StatsCalendar.today()

    @State private var selected: Int?

    private let cell: CGFloat = 12
    private let gap: CGFloat = 3
    private var step: CGFloat { cell + gap }
    private let labelWidth: CGFloat = 20

    var body: some View {
        let yearAgo = today - 364
        let start = yearAgo - StatsCalendar.weekday(ofDay: yearAgo)   // 그 주 월요일부터
        let weeks = (today - start) / 7 + 1
        let values = (start...today).map { counts[$0] ?? 0 }
        let level = StatsMath.makeLevel(values)
        let activeDays = (yearAgo...today).filter { (counts[$0] ?? 0) > 0 }.count
        let best = (yearAgo...today).max { (counts[$0] ?? 0, $0) < (counts[$1] ?? 0, $1) }
            .flatMap { (counts[$0] ?? 0) > 0 ? $0 : nil }
        let width = CGFloat(weeks) * step - gap
        let height = 7 * step - gap

        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("최근 1년 중 \(StatsFormat.number(activeDays))일 음악을 들었어요")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 4) {
                // 요일 이름 (월·수·금만)
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 16)
                    ForEach(0..<7, id: \.self) { row in
                        Text(row % 2 == 0 && row < 6 ? StatsFormat.weekdays[row] : "")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(height: step, alignment: .top)
                    }
                }
                .frame(width: labelWidth - 4, alignment: .leading)

                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 4) {
                        monthLabels(start: start, weeks: weeks)
                            .frame(width: width, height: 12, alignment: .leading)
                        Canvas { context, _ in
                            for d in start...today {
                                let col = (d - start) / 7
                                let row = (d - start) % 7
                                let rect = CGRect(x: CGFloat(col) * step, y: CGFloat(row) * step, width: cell, height: cell)
                                let path = Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous)
                                context.fill(path, with: .color(HeatColor.color(level(counts[d] ?? 0))))
                                if d == selected {
                                    context.stroke(path, with: .color(.primary), lineWidth: 1.5)
                                }
                            }
                        }
                        .frame(width: width, height: height)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            let col = Int(location.x / step)
                            let row = Int(location.y / step)
                            guard row >= 0, row < 7, col >= 0 else { return }
                            let d = start + col * 7 + row
                            guard d >= start, d <= today else { return }
                            selected = selected == d ? nil : d
                        }
                    }
                    .padding(.trailing, 2)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.trailing)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(detail(best: best))
                    .font(.footnote)
                    .foregroundStyle(selected == nil ? Color.secondary : Color.primary)
                    .contentTransition(.opacity)
                Spacer(minLength: Spacing.s)
                HeatLegend()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("최근 1년 청취 기록. \(detail(best: best))")
    }

    private func detail(best: Int?) -> String {
        if let selected {
            let v = counts[selected] ?? 0
            let day = "\(StatsFormat.day(selected)) \(StatsFormat.weekdays[StatsCalendar.weekday(ofDay: selected)])요일"
            return v > 0 ? "\(day)에 \(StatsFormat.number(v))곡 들었어요" : "\(day)에는 듣지 않았어요"
        }
        if let best {
            return "가장 많이 들은 날은 \(StatsFormat.day(best)), \(StatsFormat.number(counts[best] ?? 0))곡이에요"
        }
        return "아직 기록이 없어요"
    }

    private func monthLabels(start: Int, weeks: Int) -> some View {
        let calendar = StatsCalendar.local
        var labels: [MonthLabel] = []
        var previous = -1
        for col in 0..<weeks {
            let month = calendar.component(.month, from: StatsCalendar.date(ofDay: start + col * 7))
            if month != previous {
                labels.append(MonthLabel(col: col, text: "\(month)월"))
                previous = month
            }
        }
        // 첫 글자가 다음 달 이름과 겹치면 뺀다.
        if labels.count > 1, labels[1].col - labels[0].col < 3 { labels.removeFirst() }
        return ZStack(alignment: .topLeading) {
            ForEach(labels) { label in
                Text(label.text)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: CGFloat(label.col) * step)
            }
        }
    }
}

private struct MonthLabel: Identifiable {
    let col: Int
    let text: String
    var id: Int { col }
}

/// 요일(7줄) × 시간(24칸) 청취량
struct WeekHourHeatmap: View {
    let matrix: [[Int]]

    @State private var selected: (weekday: Int, hour: Int)?
    @State private var width: CGFloat = 320

    private let labelWidth: CGFloat = 18
    private let gap: CGFloat = 2

    var body: some View {
        let values = matrix.flatMap { $0 }
        let level = StatsMath.makeLevel(values)
        let step = max((width - labelWidth) / 24, 6)
        let gridHeight = step * 7
        let peak = peakSlot

        VStack(alignment: .leading, spacing: Spacing.m) {
            Canvas { context, _ in
                for w in 0..<7 {
                    context.draw(
                        Text(StatsFormat.weekdays[w]).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary),
                        at: CGPoint(x: 0, y: CGFloat(w) * step + (step - gap) / 2), anchor: .leading
                    )
                    for h in 0..<24 {
                        let rect = CGRect(x: labelWidth + CGFloat(h) * step, y: CGFloat(w) * step,
                                          width: step - gap, height: step - gap)
                        let path = Path(roundedRect: rect, cornerRadius: min(3, step / 4), style: .continuous)
                        context.fill(path, with: .color(HeatColor.color(level(matrix[w][h]))))
                        if let selected, selected.weekday == w, selected.hour == h {
                            context.stroke(path, with: .color(.primary), lineWidth: 1.5)
                        }
                    }
                }
                for h in stride(from: 0, to: 24, by: 6) {
                    context.draw(
                        Text(h == 0 ? "0시" : "\(h)시").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary),
                        at: CGPoint(x: labelWidth + CGFloat(h) * step, y: gridHeight + 9), anchor: .leading
                    )
                }
            }
            .frame(height: gridHeight + 16)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let h = Int((location.x - labelWidth) / step)
                let w = Int(location.y / step)
                guard location.x >= labelWidth, (0..<24).contains(h), (0..<7).contains(w) else { return }
                if let selected, selected.weekday == w, selected.hour == h {
                    self.selected = nil
                } else {
                    selected = (w, h)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(detail(peak: peak))
                    .font(.footnote)
                    .foregroundStyle(selected == nil ? Color.secondary : Color.primary)
                Spacer(minLength: Spacing.s)
                HeatLegend()
            }
        }
        .onChange(of: values) { _, _ in selected = nil }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("요일과 시간대별 청취량. \(detail(peak: peak))")
    }

    private var peakSlot: (weekday: Int, hour: Int)? {
        var best: (Int, Int, Int)?
        for w in 0..<7 {
            for h in 0..<24 where matrix[w][h] > (best?.2 ?? 0) {
                best = (w, h, matrix[w][h])
            }
        }
        return best.map { (weekday: $0.0, hour: $0.1) }
    }

    private func detail(peak: (weekday: Int, hour: Int)?) -> String {
        if let selected {
            let v = matrix[selected.weekday][selected.hour]
            let slot = "\(StatsFormat.weekdays[selected.weekday])요일 \(StatsFormat.hour(selected.hour))대"
            return v > 0 ? "\(slot)에 \(StatsFormat.number(v))곡 들었어요" : "\(slot)에는 듣지 않았어요"
        }
        if let peak {
            return "\(StatsFormat.weekdays[peak.weekday])요일 \(StatsFormat.hour(peak.hour))대에 가장 많이 들어요"
        }
        return "이 기간에는 기록이 없어요"
    }
}
