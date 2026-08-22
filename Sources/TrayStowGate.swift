import CoreGraphics
import Foundation

/// Ступень убирания колоды (`TR-41`) — ОДНА чистая структура, в которой живут
/// и состояние ступени, и все решения о нём.
///
/// Почему так. Переход «лента раскрыта → колода собрана» работает потому, что
/// его логика заперта в `TrayDetentModel`: состояние внутри, меняется одним
/// методом, обработчик жеста не имеет своих полей и ничего не решает. Ступень
/// я шесть раз писал иначе — раскладывал флаги по менеджеру и перехватывал ход
/// ветками, — и каждый раз находился путь, где флаг некому обнулить: лента
/// залипала, фаза переключалась сама, свайпы переставали доходить.
///
/// Здесь весь вход приходит в один метод: фаза жеста, ось, дельта, скорость и
/// то, стоит ли лента у упора. Наружу выдаётся решение, что делать. Обнулять
/// снаружи нечего, потому что снаружи ничего и не хранится.
struct TrayStowGate: Equatable {
    /// Фаза ленты: убрана ли колода. ДИСКРЕТНА и меняется только вместе со
    /// щелчком — ни движение, ни отпускание, ни вставка снимка её не трогают.
    private(set) var stowed = false
    /// Напряжение текущего жеста, pt сырого хода пальца.
    private(set) var strain: CGFloat = 0
    /// Разрешён ли ТЕКУЩЕМУ жесту вход на ступень. Выдаётся в начале жеста и
    /// на следующий не переходит: одним движением через две фазы не пройти.
    private(set) var permitted = false
    /// Жест ИЗРАСХОДОВАН срабатыванием: до самого его конца ни движение, ни
    /// инерция никуда не идут.
    ///
    /// Без этого остаток жеста уходил ленте: щелчок вернул колоду, пальцы
    /// продолжают движение — и лента раскрывалась, то есть из убранной
    /// колоды в раскрытую ленту можно было попасть одним жестом (приёмка
    /// 21.08.2026). Конец жеста при этом обязан проходить СКВОЗЬ блокировку,
    /// иначе лента остаётся в состоянии «жест идёт» и не садится.
    private(set) var spent = false

    /// Форма события жеста. Инерция отделена от движения пальцем: хвост,
    /// летящий после отрыва, ступень не двигает.
    enum Kind: Equatable { case began, changed, ended, cancelled, momentum }

    struct Input: Equatable {
        var kind: Kind
        /// Дельта вдоль оси ленты; положительная ведёт к сбору.
        var delta: CGFloat = 0
        var velocity: CGFloat = 0
        /// Ось жеста вертикальная. Ступень живёт только на ней.
        var verticalAxis: Bool = true
        /// Лента стоит у упора сбора.
        var deckGathered: Bool = false
    }

    /// Что ступень просит сделать. Больше решений наружу не выходит.
    enum Outcome: Equatable {
        /// Событие ступени не касается и ленте не отдаётся.
        case ignore
        /// Натяжение: колода отходит от предела фазы на `shift`.
        case tension(shift: CGFloat)
        /// Щелчок: уход колоды на ступень.
        case fire(velocity: CGFloat)
        /// Щелчок: возврат колоды.
        case recall(velocity: CGFloat)
        /// Напряжение снимается пружиной, без щелчка.
        case release
        /// Ход отдаётся ленте, как обычно.
        case pass
    }

    mutating func handle(_ input: Input) -> Outcome {
        switch input.kind {
        case .began:
            strain = 0
            spent = false
            // Ступень открыта жесту, чьё НАЧАЛО пришлось на собранную колоду
            // или на убранную, и только по вертикали.
            permitted = input.verticalAxis && (input.deckGathered || stowed)
            return stowed ? .ignore : .pass

        case .ended, .cancelled:
            // Бросок засчитывается ПО НАМЕРЕНИЮ — при отпускании, а не по ходу
            // движения (`TR-36`). Уверенный флик, не дотянувший до порога,
            // читался бы как «не сработало».
            if input.kind == .ended, permitted, !spent,
               TrayStow.fires(strain: strain, velocity: input.velocity, releasing: true) {
                strain = 0
                permitted = false
                spent = true
                stowed.toggle()
                return stowed ? .fire(velocity: input.velocity) : .recall(velocity: input.velocity)
            }
            let hadStrain = strain > 0.0001
            strain = 0
            permitted = false
            spent = false
            // Любая форма завершения обнуляет напряжение: иначе остаток
            // доживает до следующего жеста и досчитывается до порога сам.
            return hadStrain ? .release : (stowed ? .ignore : .pass)

        case .momentum:
            // Инерция ступень не двигает: направление хвоста пользователь не
            // показывал. Израсходованному жесту она тем более не нужна.
            if spent { return .ignore }
            if permitted, strain > 0.0001 { return .ignore }
            return stowed ? .ignore : .pass

        case .changed:
            return handleMove(input)
        }
    }

    private mutating func handleMove(_ input: Input) -> Outcome {
        // Сработавшая ступень забирает жест целиком: остаток хода никуда не
        // идёт до самого его конца.
        if spent { return .ignore }
        // В убранной фазе горизонтальный ход не делает НИЧЕГО: ни возврата,
        // ни раскрытия ленты, ни смены оси.
        if stowed, !input.verticalAxis { return .ignore }
        guard permitted else { return stowed ? .ignore : .pass }

        // Направление, копящее напряжение: у собранной колоды это ход в упор,
        // у убранной — обратный.
        let loading = stowed ? -input.delta : input.delta
        if !stowed, !input.deckGathered { return .pass }

        if loading > 0 {
            strain += loading
            guard TrayStow.fires(strain: strain, velocity: input.velocity) else {
                return .tension(shift: TrayStow.shift(strain: strain))
            }
            // Щелчок меняет фазу и просит увести координату — одним действием,
            // поэтому разойтись им негде.
            strain = 0
            permitted = false
            spent = true
            stowed.toggle()
            return stowed ? .fire(velocity: input.velocity) : .recall(velocity: input.velocity)
        }
        if strain > 0.0001 {
            strain = max(0, strain - abs(loading))
            return .tension(shift: TrayStow.shift(strain: strain))
        }
        // Убранной колоде за пределом фазы двигаться некуда.
        return stowed ? .ignore : .pass
    }

    /// Отзывает разрешение, не трогая фазу: жест сменил ось и больше не
    /// вправе вести ступень.
    mutating func revokePermission() {
        permitted = false
        strain = 0
    }

    /// Сброс при смене состава ленты: снимков не осталось — держать нечего.
    mutating func reset() {
        stowed = false
        strain = 0
        permitted = false
        spent = false
    }
}
