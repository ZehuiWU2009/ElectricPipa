import Foundation
import CoreGraphics

/// 观琴页的语义层。
///
/// 三维资产只负责外观，不参与命中判定。每处可点部位在这里有稳定的 ID、
/// 中英介绍和一个锚点；命中区域用参考像素定义，和 Pipa3DGeometry 共用
/// 同一套坐标。相机只负责把触点 unproject 回乐器空间，本文件不关心相机。
///
/// 坐标沿用 Pipa3DGeometry 的 506 x 1557 参考图像素：
///   y = 0 琴头顶端，y = 1557 琴身底端，山口 y = 268，覆手 y = 1441。
/// 正面与背面共用同一套 x/y，靠 z 区分；侧面锚点落在侧板厚度的一半处。
///
/// 只依赖 Foundation 和 CoreGraphics，可和 Pipa3DGeometry.swift 一起单独
/// typecheck，不需要 SwiftUI 或 AudioEngine。

/// 观琴页把可转的视角归成三面。热点、命中与部位列表都按面过滤，
/// 避免正面的琴头在背面也被点到。
enum PipaViewFace {
    case front
    case back
    case side

    /// 把绕竖轴的转角归成三面。阈值落在热点换面的中间位置，
    /// 小幅摆动不会让热点反复跳动。
    static func fromYaw(_ yaw: Double) -> PipaViewFace {
        let a = abs(yaw)
        if a < 55 * .pi / 180 { return .front }
        if a < 125 * .pi / 180 { return .side }
        return .back
    }
}

/// 只保留三面真正看得见、值得讲的部位。rawValue 是持久化 key，
/// 写进书签或本地化表时不要改。
enum PipaPart: String, CaseIterable, Identifiable {
    case head
    case pegs
    case nut
    case xiang
    case pin
    case soundboard
    case bridge
    case phoenix
    case back
    case body

    var id: String { rawValue }
}

struct PipaPartInfo {
    let part: PipaPart
    /// 该部位归属的观察面。弦轴正反两面都能看到，因此有两条记录。
    let face: PipaViewFace
    let zhName: String
    let enName: String
    let zhDetail: String
    let enDetail: String
    /// 介绍卡片引线指向的位置，参考像素坐标。
    let anchorPixel: CGPoint
    /// 锚点在乐器空间的深度，正面为 0，背面为 -bodyThickness。
    let anchorZ: Double
}

enum PipaPartAnnotations {

    // MARK: - 介绍数据

    /// 正面七处、背面三处、侧面一处。弦轴两面各一条，文案各自对应所见。
    static let all: [PipaPartInfo] = [
        // MARK: 正面
        PipaPartInfo(
            part: .head, face: .front, zhName: "琴头", enName: "Head",
            zhDetail: "琴头多做成形如祥云的如意头，取如意吉祥之意，也承托四根弦轴。燕尾头、凤尾头、龙头等形制亦见于传统琵琶。",
            enDetail: "The head is usually carved as a jade-like ruyi cloud, a Chinese emblem of good fortune, and frames the four pegs. Swallow-tail, phoenix-tail and dragon forms appear on older instruments.",
            anchorPixel: CGPoint(x: 247, y: 70), anchorZ: 0),

        PipaPartInfo(
            part: .pegs, face: .front, zhName: "弦轴", enName: "Tuning pegs",
            zhDetail: "弦轴又称轸子，四根分别系子弦、中弦、老弦、缠弦。转轴调弦，正是《琵琶行》里转轴拨弦三两声的那一步；传统用料为牛角或红木，须韧性适中。",
            enDetail: "Also called zhenzi, the four pegs tension the zi, zhong, lao and chan strings. Turning them is the act described in Bai Juyi's Tang poem Pipa Xing. Horn and hardwood are the traditional materials.",
            anchorPixel: CGPoint(x: 140, y: 190), anchorZ: 0),

        PipaPartInfo(
            part: .nut, face: .front, zhName: "山口", enName: "Nut",
            zhDetail: "山口在第一相之上，刻四道弦槽安放琴弦，是空弦振动的起点。古人以山喻其高、以口喻其纳弦，一个名字说尽了它的位置与用处。",
            enDetail: "Above the first xiang, the nut carries four grooves that fix the speaking length of each open string. Its Chinese name means mountain mouth, describing both its height and its role.",
            anchorPixel: CGPoint(x: 253, y: 268), anchorZ: 0),

        PipaPartInfo(
            part: .xiang, face: .front, zhName: "相", enName: "Xiang",
            zhDetail: "相是琴颈上部六个按音音位，相邻两音相隔半音，多用牛角、象牙或红木制成。明代朱载堉最早用数学阐明十二平均律，今日琵琶相与品的排布正沿这一律制。",
            enDetail: "Six xiang bars on the upper neck, a semitone apart, are cut from horn, ivory or hardwood. The Ming scholar Zhu Zaiyu gave the first mathematical account of equal temperament, the system behind the modern Pipa's layout.",
            anchorPixel: CGPoint(x: 247, y: 458), anchorZ: 0),

        PipaPartInfo(
            part: .pin, face: .front, zhName: "品", enName: "Pin",
            zhDetail: "品是音箱上的二十四个按音音位，竹制，相邻两品为半音。白居易写大弦嘈嘈如急雨、小弦切切如私语，音阶就落在一根根竹品之间。",
            enDetail: "Twenty-four bamboo frets run down the body, each a semitone from the next. Bai Juyi heard the loud strings like sudden rain and the soft ones like whispering across just such a scale.",
            anchorPixel: CGPoint(x: 247, y: 850), anchorZ: 0),

        PipaPartInfo(
            part: .soundboard, face: .front, zhName: "面板", enName: "Soundboard",
            zhDetail: "面板多用桐木，与背板合抱成梨形音箱，把琴弦的振动送向空中。琵琶二字与果名枇杷同音，梨形琴身取的正是果实圆满的意象。",
            enDetail: "A paulownia soundboard joins the hardwood back into a pear-shaped resonator and radiates the strings. The instrument's name shares its sound with the loquat, whose rounded form the body echoes.",
            anchorPixel: CGPoint(x: 300, y: 1120), anchorZ: 0),

        PipaPartInfo(
            part: .bridge, face: .front, zhName: "覆手", enName: "Bridge",
            zhDetail: "覆手在面板下端，承托四根琴弦并把振动传入琴面。转轴拨弦三两声，未成曲调先有情，拨弦处正在这覆手之上。",
            enDetail: "The bridge sits low on the soundboard, carrying the strings and passing their vibration into the wood. It is here that the first notes of Pipa Xing are struck.",
            anchorPixel: CGPoint(x: 247, y: 1441), anchorZ: 0),

        // MARK: 背面
        PipaPartInfo(
            part: .pegs, face: .back, zhName: "弦轴", enName: "Tuning pegs",
            zhDetail: "从背面可见四根弦轴左右各二，穿过琴头咬住弦孔。传统做法不靠金属螺杆，而用木轴的锥度自锁，调准后不易走音。",
            enDetail: "From behind, four pegs pass through the head in two pairs. Traditional pegs lock by their taper rather than by a screw, holding the tuning once it is set.",
            // 背面照片贴时做了水平翻转：照片左侧的轴（像素 x≈140）显示到
            // 参考系 x≈506-140=366，正是背面视角的左上轴。取 350 以落在
            // 弦轴语义命中区内（离中轴 103，在 40...118 之间）。
            anchorPixel: CGPoint(x: 350, y: 200), anchorZ: -Pipa3DGeometry.bodyThickness),

        PipaPartInfo(
            part: .phoenix, face: .back, zhName: "凤凰台", enName: "Phoenix platform",
            zhDetail: "凤凰台在琴头后方，又名琴枕，常刻制作者姓名与制作年月，是传统器物的款识。凤为祥瑞之鸟，此名取凤鸣岐山的吉意；用料有红木、牛角与骨制品。",
            enDetail: "Behind the head, the phoenix platform records the maker's name and date, continuing the Chinese tradition of inscriptions. The phoenix is an auspicious bird whose song was said to herald good times. Hardwood, horn and bone are used.",
            anchorPixel: CGPoint(x: 247, y: 178), anchorZ: -Pipa3DGeometry.bodyThickness),

        PipaPartInfo(
            part: .back, face: .back, zhName: "背板", enName: "Back",
            zhDetail: "背板多用紫檀、红木等硬木，取整木剖成半瓢形，与面板粘合为共鸣箱。木纹如流水行云，是琵琶音色温厚的来处。",
            enDetail: "Cut from a single piece of dense hardwood, the back is hollowed into a half-gourd and joined to the soundboard. Its flowing grain helps give the Pipa its warm tone.",
            anchorPixel: CGPoint(x: 247, y: 1120), anchorZ: -Pipa3DGeometry.bodyThickness),

        // MARK: 侧面
        PipaPartInfo(
            part: .body, face: .side, zhName: "琴腹", enName: "Body",
            zhDetail: "琴腹由面板、背板与侧板围成梨形共鸣腔，侧板厚约数厘米，让音量与余韵得以生长。古人称琴身为半瓢，指的正是这中空如瓢的形制。",
            enDetail: "The body is a pear-shaped cavity closed by the soundboard, back and ribs. A few centimetres deep, it lets the strings bloom. Classical texts call the shape a half gourd.",
            anchorPixel: CGPoint(x: 247, y: 1120), anchorZ: -Pipa3DGeometry.bodyThickness / 2)
    ]

    /// 弦轴正反各一条，不能用 uniqueKeysWithValues 直接建字典。
    private static func firstEntry(for part: PipaPart, on face: PipaViewFace? = nil)
        -> PipaPartInfo? {
        if let face {
            return all.first { $0.part == part && $0.face == face }
        }
        return all.first { $0.part == part }
    }

    static func info(_ part: PipaPart, face: PipaViewFace? = nil) -> PipaPartInfo {
        firstEntry(for: part, on: face)
            ?? firstEntry(for: part)!
    }

    /// 当前观察面上的全部可点部位，顺序即介绍卡横条顺序。
    static func entries(on face: PipaViewFace) -> [PipaPartInfo] {
        all.filter { $0.face == face }
    }

    static func listedParts(on face: PipaViewFace) -> [PipaPart] {
        entries(on: face).map(\.part)
    }

    /// 介绍卡片锚点转成本地 3D 坐标，和 Pipa3DGeometry 的乐器空间一致。
    static func anchorLocal(_ part: PipaPart, face: PipaViewFace) -> Pipa3DPoint {
        let e = info(part, face: face)
        return Pipa3DGeometry.local(xPixel: e.anchorPixel.x,
                                    yPixel: e.anchorPixel.y,
                                    z: e.anchorZ)
    }

    // MARK: - 语义命中

    /// 按面解析乐器空间的参考像素坐标。正面七处、背面三处、侧面一处，
    /// 已删去的部位不会再被命中到。
    static func hit(x: Double, y: Double, face: PipaViewFace) -> PipaPart? {
        switch face {
        case .front: return hitFront(x: x, y: y)
        case .back: return hitBack(x: x, y: y)
        case .side: return hitSide(x: x, y: y)
        }
    }

    private static func hitFront(x: Double, y: Double) -> PipaPart? {
        if hitPegs(x: x, y: y) { return .pegs }
        if abs(y - Pipa3DGeometry.nutPixel) < 12,
           x >= 208, x <= 286 { return .nut }
        if abs(y - Pipa3DGeometry.bridgePixel) < 28,
           x >= 172, x <= 322 { return .bridge }
        if hitXiang(x: x, y: y) { return .xiang }
        if hitPin(x: x, y: y) { return .pin }

        let half = Pipa3DGeometry.bodyHalfWidth(atY: min(max(y, 0), 1557))
        if y > Pipa3DGeometry.stopRows[7], abs(x - 247) <= half + 8 {
            return .soundboard
        }
        if y >= headTop, y < Pipa3DGeometry.nutPixel - 4 { return .head }
        return nil
    }

    private static func hitBack(x: Double, y: Double) -> PipaPart? {
        if hitPegs(x: x, y: y) { return .pegs }
        if y >= 120, y <= 248, abs(x - 247) <= 30 { return .phoenix }
        let half = Pipa3DGeometry.bodyHalfWidth(atY: min(max(y, 0), 1557))
        if y > Pipa3DGeometry.stopRows[7], abs(x - 247) <= half + 8 {
            return .back
        }
        return nil
    }

    private static func hitSide(x: Double, y: Double) -> PipaPart? {
        let half = Pipa3DGeometry.bodyHalfWidth(atY: min(max(y, 0), 1557))
        guard y > Pipa3DGeometry.nutPixel, abs(x - 247) <= half + 24 else { return nil }
        return .body
    }

    // MARK: - 小部位区域

    /// 四个弦轴分布在琴头两侧，y 约 92 至 228，离中轴 40 至 118 像素。
    private static func hitPegs(x: Double, y: Double) -> Bool {
        guard y >= 92, y <= 228 else { return false }
        let d = abs(x - 247)
        return d >= 40 && d <= 118
    }

    /// 琴头顶端的参考像素下界。
    private static let headTop: Double = 40

    /// stopRows 的 1 至 6 项是六个相，7 至 30 项是二十四个品。
    private static func hitXiang(x: Double, y: Double) -> Bool {
        guard abs(x - 247) <= 52 else { return false }
        return (1...6).contains { abs(y - Pipa3DGeometry.stopRows[$0]) < 8 }
    }

    private static func hitPin(x: Double, y: Double) -> Bool {
        guard abs(x - 247) <= Pipa3DGeometry.bodyHalfWidth(atY: y) else { return false }
        return (7...30).contains { abs(y - Pipa3DGeometry.stopRows[$0]) < 9 }
    }
}
