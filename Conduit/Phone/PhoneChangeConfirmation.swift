//
//  PhoneChangeConfirmation.swift
//  Conduit
//
//  The user's own yes to a change or deletion a voice call read back, in
//  each of the app's languages: "yes, delete it", "mark it done",
//  "ja, lösch es", "sí, bórralo", "はい、削除して", "好的，删掉吧". The words
//  of how a user asks ("delete the event") never pass, so a model that
//  skips asking can't take the request as the answer.
//

import Foundation

enum PhoneChangeConfirmation {
    /// Words that agree to the read-back change, in English, then German,
    /// Spanish, French, Portuguese, Russian, Italian, Polish, Turkish,
    /// Indonesian and Korean (the shipped languages with word breaks). No
    /// word of a no ("don't", "nicht", "не", "jangan", "마") is here, so
    /// a sentence with one never passes.
    static let agreeing: Set<String> = verbs.union(pointing).union([
        "please", "go", "do", "and", "then", "just", "the", "event", "reminder", "all", "of", "done", "as", "alarm",
        "timer", "a",
        "bitte", "und", "dann", "einfach", "mal", "nur", "den", "die", "der", "dem", "termin", "eintrag",
        "erinnerung", "wecker", "alle", "als", "erledigt", "auch", "machen", "mach", "gerne", "gern",
        "el", "la", "los", "las", "evento", "recordatorio", "alarma", "temporizador", "como", "hecho", "hecha",
        "completado", "completada", "y", "entonces", "por", "favor", "todo", "todos", "todas", "adelante",
        "le", "les", "l", "événement", "evenement", "rendez", "rappel", "alarme", "minuteur", "réveil", "reveil",
        "et", "alors", "d", "accord", "s", "il", "te", "plaît", "plait", "comme", "fait", "faite", "terminé",
        "termine", "tous", "toutes", "à", "jour", "vas", "allez", "juste", "deux", "vous",
        "o", "os", "lembrete", "feito", "feita", "concluído", "concluido", "concluída", "concluida", "e",
        "então", "entao", "pra", "para", "dois", "duas",
        "событие", "напоминание", "будильник", "таймер", "как", "выполненное", "выполненным", "сделанным",
        "и", "тогда", "просто", "пожалуйста", "все", "всё",
        "promemoria", "sveglia", "fatto", "fatta", "completato", "completata", "allora", "per",
        "favore", "tutti", "tutte", "pure", "va", "bene",
        "wydarzenie", "przypomnienie", "budzik", "minutnik", "jako", "zrobione", "wykonane", "ukończone",
        "ukonczone", "wtedy", "proszę", "prosze", "wszystkie", "nazwę", "nazwe",
        "etkinliği", "etkinligi", "hatırlatıcıyı", "hatirlaticiyi", "alarmı", "alarmi", "zamanlayıcıyı",
        "zamanlayiciyi", "lütfen", "lutfen", "ve", "zaman", "hepsini", "tamamlandı", "tamamlandi", "olarak",
        "yeniden", "adlandır", "adlandir",
        "acara", "pengingat", "sebagai", "selesai", "dan", "lalu", "tolong", "silakan", "saja", "aja", "nama",
        "semua", "sudah",
        "일정", "이벤트", "미리", "알림", "리마인더", "알람", "타이머", "주세요", "줘", "줘요", "그럼", "그리고",
        "그냥", "완료", "완료로", "이름", "을", "를",
    ])

    /// Verbs of the change itself, among them the forms that carry their
    /// own "it" ("bórralo", "cancellalo"), which count as pointing too.
    static let verbs: Set<String> = Set([
        "delete", "remove", "change", "move", "update", "rename", "reschedule", "mark", "complete",
        "lösche", "lösch", "löschen", "losche", "losch", "entferne", "entfernen", "ändere", "änder", "ändern",
        "andere", "verschiebe", "verschieb", "verschieben", "aktualisiere", "aktualisieren", "benenne",
        "umbenennen", "markiere", "markieren", "hak", "abhaken", "erledige", "erledigen",
        "borra", "borrar", "elimina", "eliminar", "quita", "quitar", "cambia", "cambiar", "mueve", "mover",
        "actualiza", "actualizar", "renombra", "renombrar", "reprograma", "marca", "marcar", "completa",
        "supprime", "supprimez", "supprimer", "efface", "effacez", "effacer", "enlève", "enleve", "enlevez",
        "retire", "retirez", "modifie", "modifiez", "modifier", "déplace", "deplace", "déplacez", "deplacez",
        "mets", "mettez", "renomme", "renommez", "reprogramme", "marque", "marquez", "termine", "terminez",
        "complète",
        "apaga", "apague", "apagar", "exclui", "exclua", "excluir", "deleta", "remova", "remover", "tira",
        "tire", "muda", "mude", "mudar", "altera", "altere", "alterar", "mova", "atualiza", "atualize",
        "atualizar", "renomeia", "renomeie", "reagenda", "reagende", "conclui", "conclua",
        "удали", "удалите", "удалить", "убери", "уберите", "измени", "измените", "перенеси", "перенесите",
        "обнови", "обновите", "переименуй", "переименуйте", "отметь", "отметьте", "заверши", "завершите",
        "cancella", "rimuovi", "togli", "modifica", "sposta", "aggiorna", "rinomina", "segna",
        "usuń", "usun", "usuńcie", "skasuj", "zmień", "zmien", "przenieś", "przenies", "zaktualizuj",
        "aktualizuj", "oznacz", "ukończ", "ukoncz", "zakończ", "zakoncz",
        "sil", "silin", "kaldır", "kaldir", "değiştir", "degistir", "taşı", "tasi", "güncelle", "guncelle",
        "işaretle", "isaretle", "tamamla",
        "hapus", "hapuskan", "hapusnya", "buang", "ubah", "ganti", "pindahkan", "perbarui", "perbaharui",
        "tandai", "selesaikan",
        "삭제해", "삭제해요", "삭제해줘", "지워", "지워요", "지워줘", "없애", "없애줘", "바꿔", "바꿔요", "바꿔줘",
        "변경해", "변경해요", "변경해줘", "옮겨", "옮겨요", "옮겨줘", "업데이트해", "업데이트해줘", "완료해",
        "완료해요", "완료해줘", "표시해", "표시해줘", "체크해", "체크해줘",
    ]).union(verbsWithIt)

    /// Imperatives that carry their own object: "delete it" in one word.
    static let verbsWithIt: Set<String> = [
        "bórralo", "borralo", "bórrala", "borrala", "bórralos", "borralos", "bórralas", "borralas",
        "elimínalo", "eliminalo", "elimínala", "eliminala", "elimínalos", "eliminalos", "quítalo", "quitalo",
        "quítala", "quitala", "cámbialo", "cambialo", "cámbiala", "cambiala", "muévelo", "muevelo", "muévela",
        "muevela", "actualízalo", "actualizalo", "actualízala", "actualizala", "márcalo", "marcalo",
        "márcala", "marcala", "complétalo", "completalo", "complétala", "completala",
        "apaga-o", "cancellalo", "cancellala", "cancellali", "eliminali", "rimuovilo", "rimuovila",
        "toglilo", "toglila", "modificalo", "modificala", "spostalo", "spostala", "aggiornalo",
        "aggiornala", "segnalo",
    ]

    /// Words that point back at what was read out ("it", "that one"), or a
    /// yes. Articles ("the", "la", "le") aren't here: "borra la alarma" is
    /// how a user asks.
    static let pointing: Set<String> = verbsWithIt.union([
        "yes", "yeah", "yep", "ok", "okay", "sure", "ahead", "it", "that", "this", "them", "both", "one",
        "ja", "klar", "es", "das", "ihn", "sie", "dies", "diese", "diesen", "dieses", "beide", "beides",
        "sí", "si", "vale", "claro", "eso", "esto", "ese", "esa", "este", "esta", "lo", "ambos", "ambas",
        "oui", "ça", "ca", "cela", "ceci",
        "sim", "isso", "isto", "esse", "essa", "ele", "ela", "eles", "elas", "pode",
        "да", "ок", "окей", "его", "её", "ее", "их", "это", "этот", "эту", "эти", "оба", "обе", "давай", "давайте",
        "sì", "certo", "quello", "quella", "questo", "questa", "entrambi", "entrambe",
        "tak", "okej", "to", "ją", "je", "oba", "obie", "dobrze",
        "evet", "tamam", "onu", "bunu", "şunu", "sunu", "onları", "onlari", "ikisini", "olur",
        "ya", "iya", "oke", "boleh", "itu", "ini", "semuanya", "keduanya",
        "네", "예", "응", "좋아요", "좋아", "그래", "그래요", "그거", "그것", "이거", "이것", "그걸", "이걸", "둘", "다", "모두",
    ])

    /// What cancels an alarm, which is how most people decline anything
    /// else ("cancel", "annule", "取消"): it agrees only to cancelling one.
    static let alarmVerbs: Set<String> = [
        "cancel", "turn", "off",
        "abbrechen", "storniere", "stornieren", "ausschalten", "aus", "schalte", "stell", "stelle",
        "cancela", "cancelar", "cancélalo", "cancelalo", "cancélala", "cancelala", "desactiva", "desactívala",
        "desactivala", "apaga",
        "annule", "annulez", "annuler", "désactive", "desactive", "désactivez", "desactivez",
        "cancele", "desativa", "desative", "desliga", "desligue",
        "отмени", "отмените", "отменить", "выключи", "выключите",
        "annulla", "annullalo", "annullala", "disattiva", "disattivala", "disattivalo",
        "anuluj", "wyłącz", "wylacz",
        "iptal", "et", "kapat",
        "batalkan", "matikan",
        "취소해", "취소해요", "취소해줘", "꺼", "꺼줘", "꺼요", "해제해", "해제해줘",
    ]

    static func confirms(_ words: String, cancelsAlarm: Bool) -> Bool {
        guard !words.contains("?"), !words.contains("？") else { return false }
        let lowered = words.lowercased()
        if confirmsWithoutSpaces(lowered, cancelsAlarm: cancelsAlarm) { return true }
        let said = lowered.split(whereSeparator: { !$0.isLetter }).map(String.init)
        var agreeing = Self.agreeing
        var verbs = Self.verbs
        if cancelsAlarm {
            agreeing.formUnion(alarmVerbs)
            verbs.formUnion(alarmVerbs)
        }
        // "supprime-le", "apaga-o": the pronoun hangs off the verb.
        let pointsByPronoun = lowered.range(of: #"\p{L}-(le|la|les|lo|o|a)\b"#, options: .regularExpression) != nil
        return (1...8).contains(said.count) && said.allSatisfy(agreeing.contains) && said.contains(where: verbs.contains)
            && (pointsByPronoun || said.contains(where: Self.pointing.contains))
    }

    // MARK: Japanese and Chinese

    /// Japanese and Chinese have no spaces between words, so the whole
    /// answer is matched: an optional yes, what it points at, the verb and
    /// a polite ending, with a yes or a pointer present ("はい、削除して",
    /// "それを消してください", "好的，删掉吧", "把它删了"). A "don't"
    /// ("しないで", "不要", "别") matches nothing.
    private static func confirmsWithoutSpaces(_ lowered: String, cancelsAlarm: Bool) -> Bool {
        let text = String(String.UnicodeScalarView(lowered.unicodeScalars.filter { CharacterSet.letters.contains($0) }))
        guard !text.isEmpty, text.unicodeScalars.contains(where: { (0x3040...0x9FFF).contains($0.value) }) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        for (regex, groups) in cancelsAlarm ? alarmPatterns : patterns {
            guard let match = regex.firstMatch(in: text, range: range) else { continue }
            if groups.contains(where: { match.range(withName: $0).location != NSNotFound }) { return true }
        }
        return false
    }

    /// Japanese, then Chinese, each with the groups that hold a yes or a
    /// pointer: compiled once.
    private static let patterns = compiled(verbs: cjkVerbs)
    private static let alarmPatterns = compiled(verbs: cjkVerbs + "|" + cjkAlarmVerbs)

    private static func compiled(verbs: String) -> [(NSRegularExpression, [String])] {
        let japanese = "^(?<yes>\(japaneseYes))?(?<point>\(japanesePointing))?(?:\(verbs))(?:\(japaneseEndings))?$"
        let chinese = "^(?<yes>\(chineseYes))?(?<point>把?(?:\(chinesePointing)))?(?:\(verbs))(?<after>\(chinesePointing))?(?:\(chineseEndings))?$"
        // Constant patterns: one that doesn't compile fails every test of it.
        return [(japanese, ["yes", "point"]), (chinese, ["yes", "point", "after"])].map { pattern, groups in
            (try! NSRegularExpression(pattern: pattern), groups)
        }
    }

    private static let japaneseYes = "はい|ええ|うん|お願いします|おねがいします|いいよ|いいです|オーケー"
    private static let japanesePointing = "(?:それ|これ|あれ|両方|全部|二つとも)(?:を|も)?"
    private static let japaneseEndings = "ください|下さい|くれ|お願いします|おねがいします|ちょうだい|ね|よ"
    private static let chineseYes = "是的|是|好的|好|对|對|可以|行|嗯"
    private static let chinesePointing = "它|这个|這個|那个|那個|这些|這些|都|两个都|兩個都"
    private static let chineseEndings = "吧|了|掉|吧了"
    /// Both languages' verbs: a Japanese one never reads as Chinese, and
    /// the other way round, in a whole-answer match.
    private static let cjkVerbs = [
        "削除して", "消して", "削除しておいて", "消しておいて", "変更して", "移動して", "動かして", "更新して",
        "名前を変えて", "完了にして", "完了して", "済みにして", "チェックして",
        "删除", "刪除", "删掉", "刪掉", "删了", "刪了", "移除", "去掉", "修改", "更改", "改", "移动", "移動",
        "更新", "标记为完成", "標記為完成", "标为完成", "標為完成", "完成",
    ].joined(separator: "|")
    private static let cjkAlarmVerbs = [
        "キャンセルして", "止めて", "とめて", "オフにして", "解除して",
        "取消", "关掉", "關掉", "关了", "關了",
    ].joined(separator: "|")
}
