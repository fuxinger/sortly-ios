import Foundation

/// Continents, derived deterministically from ISO 3166-1 alpha-2 country codes.
/// Transcontinental countries are assigned to the continent of their capital
/// (e.g. TR, RU → Europe; EG → Africa), which is the most common convention.
public enum Continent: String, Sendable, Codable, CaseIterable {
    case africa, antarctica, asia, europe, northAmerica, oceania, southAmerica

    public static func forCountryCode(_ code: String) -> Continent? {
        table[code.uppercased()]
    }

    private static let table: [String: Continent] = {
        var t: [String: Continent] = [:]
        func add(_ codes: String, _ continent: Continent) {
            for code in codes.split(separator: " ") { t[String(code)] = continent }
        }
        add("AD AL AT AX BA BE BG BY CH CY CZ DE DK EE ES FI FO FR GB GG GI GR HR HU IE IM IS IT JE LI LT LU LV MC MD ME MK MT NL NO PL PT RO RS RU SE SI SJ SK SM TR UA VA XK", .europe)
        add("AE AF AM AZ BD BH BN BT CC CN CX GE HK ID IL IN IO IQ IR JO JP KG KH KP KR KW KZ LA LB LK MM MN MO MV MY NP OM PH PK PS QA SA SG SY TH TJ TL TM TW UZ VN YE", .asia)
        add("AO BF BI BJ BW CD CF CG CI CM CV DJ DZ EG EH ER ET GA GH GM GN GQ GW KE KM LR LS LY MA MG ML MR MU MW MZ NA NE NG RE RW SC SD SH SL SN SO SS ST SZ TD TG TN TZ UG YT ZA ZM ZW", .africa)
        add("AG AI AW BB BL BM BQ BS BZ CA CR CU CW DM DO GD GL GP GT HN HT JM KN KY LC MF MQ MS MX NI PA PM PR SV SX TC TT US VC VG VI", .northAmerica)
        add("AR BO BR CL CO EC FK GF GY PE PY SR UY VE GS", .southAmerica)
        add("AS AU CK FJ FM GU KI MH MP NC NF NR NU NZ PF PG PN PW SB TK TO TV UM VU WF WS", .oceania)
        add("AQ BV HM TF", .antarctica)
        return t
    }()
}
