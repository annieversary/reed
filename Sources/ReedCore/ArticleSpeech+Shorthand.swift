import Foundation

extension ArticleSpeech {
    /// Shorthand written for reading, said in words: abbreviations ("Gov.", "St.", "et al."), times ("1am", "13:00"),
    /// amounts ("$1M", "A$10", "$5/month"), ranges ("10-15"), pairs ("24/7"), units, symbols, and roman numerals after names.
    /// Kokoro's own normalization reads these letter by letter, as fractions, or not at all.
    /// Footnote markers, emoji and the parts of a web address nobody says aloud are left out.
    /// An abbreviation's period is kept where it also ends the sentence.
    static func inWords(_ sentence: String) -> String {
        [unsaid, abbreviations, times, amounts, units, symbols, romanNumerals].reduce(sentence) { $1($0) }
            .replacing(#/ {2,}/#, with: " ").replacing(#/ (?=[,;:!?]|\.(?!\w))/#, with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func unsaid(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !($0.properties.isEmojiPresentation || $0.properties.isEmojiModifier || [0xFE0F, 0x200D].contains($0.value)
                || $0.properties.isEmoji && $0.value >= 0x2300)
        }))
        .replacing(#/\[(?:\d+|[a-z]{1,2}|note \d+|[a-z][a-z ]*(?:needed|\?))\]/#, with: "")
        .replacing(#/\b(?:https?:\/\/)?(?:www\.)?([a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,})(?:\/\S*?)?(?=[.,;:!?)\]]*(?:\s|$))/#.ignoresCase()) {
            String($0.1)
        }
    }

    // Where a sentence goes on after an abbreviation, its period would be read as a pause, so it's dropped.
    // A capital after it starts the next sentence, unless it's another abbreviation, like "9 a.m. EST".
    private static func abbreviations(_ text: String) -> String {
        text.replacing(saint()) { isSaint($0, in: text) ? "\($0.1 ?? "")Saint" : String($0.0) }
            .replacing(#/\b(Prof|Gov|Sen|Rep|Gen|Capt|Lt|Col|Sgt|Rev|Pres|Hon|Adm|Maj|Cpl|Fr|Supt|Pt|Ste)\.\s+(?=[A-Z])/#) {
                "\(titles[String($0.1)] ?? String($0.1)) "
            }
            .replacing(#/\bJct\.\s?/#, with: "Junction ")
            .replacing(#/\b(Mon|Tues?|Wed|Thu(?:rs?)?|Fri|Sat|Sun)\.(?=,|\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)|\s+\d)/#) {
                days[String($0.1)] ?? String($0.0)
            }
            .replacing(#/([A-Z0-9][\w']*\s+)(Ave|Blvd|Rd|Hwy|Pkwy|Ln)\b(\.)?(\s*$|\s+(?=[A-Z](?![A-Z.])))?/#) {
                "\($0.1)\(streets[String($0.2)] ?? String($0.2))\(period($0.3, before: $0.4))"
            }
            .replacing(#/\bPh\.?\s?D\b(\.)?(\s*$|\s+(?=[A-Z](?![A-Z.])))?/#) { "P H D\(period($0.1, before: $0.2))" }
            .replacing(#/\b((?:[A-Z]\.){2,})(\s*$)?/#) {
                "\($0.1.filter(\.isLetter).map(String.init).joined(separator: " "))\(period(".", before: $0.2))"
            }
            .replacing(#/\b(Inc|Corp|Bros|Dept|Jr|Sr|approx|ibid|et al)\.(\s*$|\s+(?=[A-Z](?![A-Z.])))?/#) {
                "\(shortWords[String($0.1)] ?? String($0.1))\(period(".", before: $0.2))"
            }
            .replacing(#/\b(?:a\.k\.a\.|aka|AKA)(?=\s)/#, with: "also known as")
            .replacing(#/\b(cf|viz)\.\s?/#) { "\($0.1 == "cf" ? "compare" : "namely") " }
            .replacing(#/\b(No|no|Fig|fig|Vol|vol|pp)\.\s?(?=\d)/#) { "\(numbered[String($0.1)] ?? String($0.1)) " }
            .replacing(#/\b(?:c|ca)\.\s?(?=\d)/#, with: "circa ")
            .replacing(#/(^|[(\s,;])([bd])\.\s?(?=\d{3,4}\b)/#) { "\($0.1)\($0.2 == "b" ? "born" : "died") " }
    }

    // Kokoro reads "AM" as a word and "a" as the article, so the meridiem is given as capital letters apart, as are time zones.
    private static func times(_ text: String) -> String {
        text.replacing(#/(^|[^\w:.])(1[0-2]|0?[1-9])(?::([0-5]\d))?\s?([AaPp])(?:\.[Mm](\.)?|[Mm])(?![A-Za-z])(\s*$|\s+(?=[A-Z](?![A-Z])))?/#) {
            "\($0.1)\(clock($0.2, $0.3)) \($0.4.uppercased()) M\(period($0.5, before: $0.6))"
        }
        .replacing(#/(^|[^\w:.])(1[3-9]|2[0-3]):([0-5]\d)(?![\d:])/#) {
            "\($0.1)\($0.3 == "00" ? "\($0.2) hundred" : clock($0.2, $0.3))"
        }
        .replacing(#/((?:[AP] M|\d|noon|midnight)\s+)(ET|EST|EDT|CT|CST|CDT|MT|MST|MDT|PT|PST|PDT|GMT|UTC|BST|CET|CEST|IST|JST|AEST|AEDT)\b/#) {
            "\($0.1)\($0.2.map(String.init).joined(separator: " "))"
        }
    }

    private static func amounts(_ text: String) -> String {
        // Kokoro reads "US" as the pronoun, and "A$" letter by letter.
        text.replacing(#/(?:\b(US|AU|A|CA|C|NZ|HK|S))?\$(\d+(?:,\d{3})*(?:\.\d+)?)(?:(?i:([kmbt]|mn|bn|tn))\b|\s?(?i:(thousand|million|billion|trillion))\b)?/#) { match in
            let (whole, country, number, letter, word) = match.output
            let scale = (letter ?? word).flatMap { scales[$0.lowercased()] }
            let place = country.flatMap { dollarCountries[String($0)] }
            switch (scale, place) {
            case (nil, nil): return String(whole)
            case let (nil, place?): return "$\(number) \(place)"
            case let (scale?, place): return "\(number) \(scale) \(place.map { "\($0) " } ?? "")dollars"
            }
        }
        .replacing(#/(\b[A-Za-z]+\s+)?\b(\d+(?:,\d{3})*(?:\.\d+)?)(K|k|M|B|T|bn|Bn|mn|tn)(?!\w)/#) { match in
            let (_, before, number, scale) = match.output
            let word = before?.trimmingCharacters(in: .whitespaces).lowercased()
            if scale == "B", let word, labeled.contains(word) { return String(match.output.0) }
            // 4K and 8K are resolutions, and a 5K is a race.
            if scale == "K", !number.contains("."), (Int(number) ?? 0) < 10 { return String(match.output.0) }
            return "\(before ?? "")\(number) \(scales[scale.lowercased()] ?? "")"
        }
        .replacing(#/(\d|%)\s?\/\s?(month|mo|year|yr|day|week|wk|hour|hr|night|person|head|user|seat|share|gallon|liter|litre|mile|pound|lb|kg|piece|ticket|unit|visit|session|minute|min)\b/#) {
            "\($0.1) per \(perUnits[String($0.2)] ?? String($0.2))"
        }
        .replacing(#/(\d+)\s?¢/#) { "\($0.1) \($0.1 == "1" ? "cent" : "cents")" }
        .replacing(#/\b(\d+(?:\.\d+)?)\s?(bps|bp)\b/#) { "\($0.1) basis \($0.1 == "1" ? "point" : "points")" }
        .replacing(#/\b(\d+(?:\.\d+)?)\s?(pp|ppt)\b/#) { "\($0.1) percentage \($0.1 == "1" ? "point" : "points")" }
        .replacing(#/\b(FY|Q[1-4]|H[12])['’]?(\d{2}|\d{4})\b/#) { "\($0.1) \($0.2)" }
        // Model numbers after a name in capitals are said in pairs, like years: an RTX 4090 is a "forty ninety".
        // Kokoro's normalization does that already for what could be a year.
        .replacing(#/\b([A-Z]{2,5})\s(\d{2})(\d{2})\b/#) { match in
            let (whole, name, high, low) = match.output
            if low == "00" || high == "19" || high == "20" { return String(whole) }
            return "\(name) \(high) \(low.first == "0" ? "oh \(low.dropFirst())" : String(low))"
        }
        .replacing(#/\b(\d+)(st|nd|rd|th)-(?=[A-Za-z])/#) { "\($0.1)\($0.2) " }
        .replacing(#/\b([A-Z]{1,3})&([A-Z]{1,3})\b/#) {
            "\($0.1.map(String.init).joined(separator: " ")) and \($0.2.map(String.init).joined(separator: " "))"
        }
    }

    private static func units(_ text: String) -> String {
        text.replacing(#/\b(240|360|480|540|720|1080|1440|2160|4320)([pi])\b/#) { "\($0.1.dropLast(2)) \($0.1.suffix(2)) \($0.2.uppercased())" }
            .replacing(#/\b(\d)['’′](\d{1,2})(?:["”″]|'')?/#) { "\($0.1) foot \($0.2)" }
            .replacing(#/\b(\d+)['’′](?=[\s,.;)]|$)/#) { "\($0.1) \($0.1 == "1" ? "foot" : "feet")" }
            .replacing(#/\b(\d+(?:\.\d+)?)°\s?([NSEW])\b/#) { "\($0.1) degrees \(compass[String($0.2)] ?? String($0.2))" }
            .replacing(#/\b(\d+(?:\.\d+)?)°(?!\s?[CFK]\b)/#) { "\($0.1) \($0.1 == "1" ? "degree" : "degrees")" }
            .replacing(#/\b(\d+(?:\.\d+)?)\s?(km/h|kmh|kph|mi/h|m/s)\b/#) { "\($0.1) \(unit(speeds[String($0.2)], for: $0.1))" }
            .replacing(#/\b(\d+(?:\.\d+)?)\s?(KB|kB|MB|GB|TB|PB|Kbps|kbps|Mbps|Gbps|Mb|Gb|Tb)\b/#) {
                "\($0.1) \(unit(dataUnits[String($0.2)], for: $0.1))"
            }
            .replacing(#/\b(\d+(?:\.\d+)?)\s?(mm|cm|nm|µm|V|W|kW|kWh|MW|MWh|GW|GWh|Wh|mAh|dB|Hz|kHz|MHz)\b/#) {
                "\($0.1) \(unit(measures[String($0.2)], for: $0.1))"
            }
            // "£5 m" is millions.
            .replacing(#/(^|[^$£€\d.,])(\d+(?:\.\d+)?) m\b/#) { "\($0.1)\($0.2) \($0.2 == "1" ? "meter" : "meters")" }
            .replacing(#/\b(\d+(?:\.\d+)?)\s?(hrs?|mins?|secs?|yrs?|mos?|wks?|ms|ns|µs)\b/#) {
                "\($0.1) \(unit(durations[String($0.2)], for: $0.1))"
            }
    }

    private static func symbols(_ text: String) -> String {
        text.replacing(#/\b([1-9]\d*)\s?[x×]\s?(\d+)\b/#) { "\($0.1) by \($0.2)" }
            .replacing(#/\b(\d+(?:\.\d+)?)[x×](?!\w)/#) { "\($0.1) times" }
            .replacing(#/\b(\d+(?:\.\d+)?)\^(-?)(\d+)\b/#) { "\($0.1) \(power($0.2, $0.3))" }
            .replacing(#/\b(\d+(?:\.\d+)?)[eE]([+-]?)(\d+)\b/#) { "\($0.1) times 10 \(power($0.2 == "-" ? "-" : "", $0.3))" }
            // Fractions have the smaller number on top, so "24/7", "50/50" and "9/11" are said as pairs.
            .replacing(#/(^|[^\w/.])(\d+)/(\d+)(?![\w/]|\.\d)/#) { match in
                let (_, before, top, bottom) = match.output
                guard let a = Int(top), let b = Int(bottom), a >= b || (a, b) == (9, 11) else { return String(match.output.0) }
                return "\(before)\(top) \(bottom)"
            }
            .replacing(#/\b24-7\b/#, with: "24 7")
            .replacing(#/(^|[^\w\-])(\d{3})-(\d{4})(?![\w\-])/#) {
                "\($0.1)\($0.2.map(String.init).joined(separator: " ")), \($0.3.map(String.init).joined(separator: " "))"
            }
            // A range rises, and a score like "3-2" is said the same way; other pairs of numbers are left alone.
            .replacing(#/(^|[^\w\-–—/.:,])(\d+(?:\.\d+)?)\s?[-–—]\s?(\d+(?:\.\d+)?)(?![\w\-–—/]|\.\d)/#) { match in
                let (_, before, low, high) = match.output
                guard let a = Double(low), let b = Double(high), b > a || low.count <= 2 && high.count <= 2 else { return String(match.output.0) }
                return "\(before)\(low) to \(high)"
            }
            .replacing(#/(\b\d{2,4}s|'\d{2}s)\s?[-–—]\s?(\d{2,4}s|'\d{2}s)\b/#) { "\($0.1) to \($0.2)" }
            // A ratio's second number has one digit, where a time's minutes have two.
            .replacing(#/(^|[^\w:.])(\d{1,2}):(\d)(?![\d:])/#) { "\($0.1)\($0.2) to \($0.3)" }
            .replacing(#/[~≈]\s?(?=[\d$£€])/#, with: "about ")
            .replacing(#/(?:>=|≥)\s?(?=[\d$£€])/#, with: "at least ")
            .replacing(#/(?:<=|≤)\s?(?=[\d$£€])/#, with: "at most ")
            .replacing(#/>\s?(?=[\d$£€])/#, with: "more than ")
            .replacing(#/<\s?(?=[\d$£€])/#, with: "less than ")
            .replacing(#/\s*(?:→|->|=>|⇒)\s*/#, with: " to ")
            .replacing("±", with: " plus or minus ").replacing("−", with: " minus ")
            .replacing("²", with: " squared").replacing("³", with: " cubed").replacing("√", with: " square root of ")
            .replacing(#/\bw\/(?!o\b)\s?/#, with: "with ").replacing(#/\bb\/c\b/#, with: "because")
            .replacing(#/(^|[\s(])#(?=\d)/#) { "\($0.1)number " }
            .replacing(#/(^|[\s(])#([A-Za-z]\w*)/#) { "\($0.1)hashtag \($0.2)" }
    }

    private static func romanNumerals(_ text: String) -> String {
        text.replacing(#/(\b[A-Z][a-z]+\s+)?\b([A-Z][a-z]+)\s+([IVXL]+)\b(?!['’]?\w)/#) { match in
            let (whole, title, name, numeral) = match.output
            guard let number = roman(numeral) else { return String(whole) }
            // "Elizabeth I" could as well be "told Elizabeth I would", so a lone I needs a title before it.
            if regnalNames.contains(String(name)), numeral != "I" || title.map({ regnalTitles.contains($0.trimmingCharacters(in: .whitespaces)) }) == true {
                return "\(title ?? "")\(name) the \(ordinal(number))"
            }
            if counted.contains(name.lowercased()) || numeral.count > 1 && !numeral.contains("L") {
                return "\(title ?? "")\(name) \(number)"
            }
            return String(whole)
        }
    }

    /// Whether `next` carries on `sentence`, which the tokenizer ended on an abbreviation: a title before a name,
    /// a weekday before a date, or one like "a.k.a." or "c." that can't end a sentence.
    static func continues(_ sentence: String, into next: String) -> Bool {
        guard let first = next.first, let word = sentence.split(separator: " ").last, word.hasSuffix(".") else { return false }
        let name = String(word.dropLast())
        if name == "St" {
            let joined = sentence + " " + next
            let end = joined.index(joined.startIndex, offsetBy: sentence.count)
            return joined.matches(of: saint()).contains { $0.range.upperBound == end && isSaint($0, in: joined) }
        }
        if titles[name] != nil { return first.isUppercase }
        if days[name] != nil { return next.wholeMatch(of: #/(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec|\d).*/#.dotMatchesNewlines()) != nil }
        if ["a.k.a", "cf", "viz", "c", "ca", "Jct"].contains(name) { return true }
        if name == "al", sentence.hasSuffix("et al.") { return first == "(" || first.isNumber }
        return false
    }

    /// "St" or "St." before a capitalized word, with the word before it.
    private static func saint() -> Regex<(Substring, Substring?)> { #/(\S+\s+)?\bSt\.?(?=\s+[A-Z])/# }

    /// Whether a match of `saint()` means Saint rather than Street, which follows a name, like "Main St.".
    /// The first word of a sentence is capitalized anyway, so it says nothing.
    private static func isSaint(_ match: Regex<(Substring, Substring?)>.Match, in text: String) -> Bool {
        guard let before = match.output.1 else { return true }
        return match.range.lowerBound == text.startIndex || before.first?.isUppercase != true
    }

    /// An abbreviation's period, with the space after it, kept only where the sentence ends there too.
    private static func period(_ dot: Substring?, before end: Substring?) -> String {
        (dot != nil && end != nil ? "." : "") + (end ?? "")
    }

    /// A time of day as it's said: "7:05" as "7 oh 5", and "7:00" as just "7".
    private static func clock(_ hour: Substring, _ minutes: Substring?) -> String {
        let hour = Int(hour).map(String.init) ?? String(hour)
        guard let minutes, minutes != "00" else { return hour }
        return minutes.first == "0" ? "\(hour) oh \(minutes.dropFirst())" : "\(hour) \(minutes)"
    }

    /// A unit's name, made plural unless there's exactly one. Hertz is the same either way.
    private static func unit(_ name: (String, String)?, for number: Substring) -> String {
        guard let (noun, rest) = name else { return "" }
        return (number == "1" || noun.hasSuffix("z") ? noun : noun + "s") + rest
    }

    /// A power as it's said: "squared", "cubed", or "to the 6th".
    private static func power(_ sign: Substring, _ exponent: Substring) -> String {
        if sign.isEmpty, exponent == "2" { return "squared" }
        if sign.isEmpty, exponent == "3" { return "cubed" }
        return "to the \(sign.isEmpty ? "" : "minus ")\(Int(exponent).map(ordinal) ?? String(exponent))"
    }

    /// The value of a roman numeral written the usual way, or nil for letters that aren't one.
    private static func roman(_ numeral: Substring) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50]
        var total = 0
        for (index, letter) in numeral.enumerated() {
            guard let value = values[letter] else { return nil }
            let next = index + 1 < numeral.count ? values[numeral[numeral.index(numeral.startIndex, offsetBy: index + 1)]] ?? 0 : 0
            total += value < next ? -value : value
        }
        let digits = [(50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var rest = total, written = ""
        for (value, letters) in digits { while rest >= value { written += letters; rest -= value } }
        return total > 0 && written == numeral ? total : nil
    }

    /// A number as an ordinal in digits, like "14th", which Kokoro's normalization says in words.
    private static func ordinal(_ number: Int) -> String {
        let suffix = (11...13).contains(number % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][number % 10] ?? "th"
        return "\(number)\(suffix)"
    }

    private static let titles = [
        "Prof": "Professor", "Gov": "Governor", "Sen": "Senator", "Rep": "Representative", "Gen": "General", "Capt": "Captain",
        "Lt": "Lieutenant", "Col": "Colonel", "Sgt": "Sergeant", "Rev": "Reverend", "Pres": "President", "Hon": "Honorable",
        "Adm": "Admiral", "Maj": "Major", "Cpl": "Corporal", "Fr": "Father", "Supt": "Superintendent", "Pt": "Point", "Ste": "Sainte",
    ]
    private static let days = [
        "Mon": "Monday", "Tue": "Tuesday", "Tues": "Tuesday", "Wed": "Wednesday", "Thu": "Thursday", "Thur": "Thursday",
        "Thurs": "Thursday", "Fri": "Friday", "Sat": "Saturday", "Sun": "Sunday",
    ]
    private static let streets = ["Ave": "Avenue", "Blvd": "Boulevard", "Rd": "Road", "Hwy": "Highway", "Pkwy": "Parkway", "Ln": "Lane"]
    private static let shortWords = [
        "Inc": "Incorporated", "Corp": "Corporation", "Bros": "Brothers", "Dept": "Department", "Jr": "Junior", "Sr": "Senior",
        "approx": "approximately", "ibid": "ibidem", "et al": "and others",
    ]
    private static let numbered = [
        "No": "Number", "no": "number", "Fig": "Figure", "fig": "figure", "Vol": "Volume", "vol": "volume", "pp": "pages",
    ]
    private static let scales = [
        "k": "thousand", "thousand": "thousand", "m": "million", "mn": "million", "million": "million",
        "b": "billion", "bn": "billion", "billion": "billion", "t": "trillion", "tn": "trillion", "trillion": "trillion",
    ]
    /// Words a number with a letter after it labels, like "Room 4B", where B isn't billions.
    private static let labeled: Set = [
        "room", "apt", "apartment", "suite", "unit", "flat", "gate", "seat", "platform", "building", "block", "floor", "row", "exit",
        "terminal", "route", "bus", "section", "part", "figure", "table", "plan", "form", "grade", "level", "size", "vitamin", "class", "type",
    ]
    private static let speeds = [
        "km/h": ("kilometer", " per hour"), "kmh": ("kilometer", " per hour"), "kph": ("kilometer", " per hour"),
        "mi/h": ("mile", " per hour"), "m/s": ("meter", " per second"),
    ]
    private static let dataUnits = [
        "KB": ("kilobyte", ""), "kB": ("kilobyte", ""), "MB": ("megabyte", ""), "GB": ("gigabyte", ""), "TB": ("terabyte", ""),
        "PB": ("petabyte", ""), "Mb": ("megabit", ""), "Gb": ("gigabit", ""), "Tb": ("terabit", ""),
        "Kbps": ("kilobit", " per second"), "kbps": ("kilobit", " per second"), "Mbps": ("megabit", " per second"),
        "Gbps": ("gigabit", " per second"),
    ]
    private static let dollarCountries = [
        "US": "US", "AU": "Australian", "A": "Australian", "CA": "Canadian", "C": "Canadian", "NZ": "New Zealand",
        "HK": "Hong Kong", "S": "Singapore",
    ]
    private static let perUnits = ["mo": "month", "yr": "year", "wk": "week", "hr": "hour", "lb": "pound", "min": "minute", "litre": "liter"]
    private static let compass = ["N": "north", "S": "south", "E": "east", "W": "west"]
    private static let measures = [
        "mm": ("millimeter", ""), "cm": ("centimeter", ""), "nm": ("nanometer", ""), "µm": ("micrometer", ""),
        "V": ("volt", ""), "W": ("watt", ""), "kW": ("kilowatt", ""), "kWh": ("kilowatt hour", ""), "MW": ("megawatt", ""),
        "MWh": ("megawatt hour", ""), "GW": ("gigawatt", ""), "GWh": ("gigawatt hour", ""), "Wh": ("watt hour", ""),
        "mAh": ("milliamp hour", ""), "dB": ("decibel", ""), "Hz": ("hertz", ""), "kHz": ("kilohertz", ""), "MHz": ("megahertz", ""),
    ]
    private static let durations = [
        "hr": ("hour", ""), "hrs": ("hour", ""), "min": ("minute", ""), "mins": ("minute", ""), "sec": ("second", ""),
        "secs": ("second", ""), "yr": ("year", ""), "yrs": ("year", ""), "mo": ("month", ""), "mos": ("month", ""),
        "wk": ("week", ""), "wks": ("week", ""), "ms": ("millisecond", ""), "ns": ("nanosecond", ""), "µs": ("microsecond", ""),
    ]
    /// Words that count with a roman numeral after them, said as a number: "World War II", "Chapter IV", "Super Bowl LVIII".
    private static let counted: Set = [
        "chapter", "part", "volume", "book", "act", "scene", "phase", "episode", "section", "article", "appendix", "stage", "level",
        "war", "bowl", "round", "season", "title", "class", "type", "tier", "category", "schedule",
    ]
    /// Names monarchs and popes take, which a roman numeral after makes an ordinal: "Henry VIII" is "Henry the Eighth".
    private static let regnalNames: Set = [
        "Henry", "Edward", "George", "William", "Richard", "Charles", "James", "Louis", "Elizabeth", "Mary", "Anne", "John", "Paul",
        "Pius", "Leo", "Gregory", "Benedict", "Innocent", "Clement", "Alexander", "Peter", "Frederick", "Philip", "Ferdinand",
        "Napoleon", "Ramesses", "Ptolemy", "Constantine", "Nicholas", "Catherine", "Ivan", "Gustav", "Christian", "Felipe", "Carlos",
        "Alfonso", "Wilhelm", "Otto", "Francis", "Joseph", "Leopold", "Rudolf", "Harald", "Olaf", "Haakon", "Frederik", "Umberto",
        "Pedro", "Manuel", "Robert", "David", "Urban", "Sixtus", "Julius", "Adrian", "Boniface", "Celestine", "Honorius", "Selim",
        "Mehmed", "Murad", "Suleiman", "Rama", "Amenhotep", "Thutmose", "Darius", "Xerxes", "Antiochus", "Victor", "Stephen",
    ]
    private static let regnalTitles: Set = [
        "King", "Queen", "Pope", "Emperor", "Empress", "Tsar", "Tsarina", "Czar", "Kaiser", "Prince", "Princess", "Pharaoh", "Sultan", "Shah",
    ]
}
