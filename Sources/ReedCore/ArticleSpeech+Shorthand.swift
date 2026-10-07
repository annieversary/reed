import Foundation

extension ArticleSpeech {
    /// Shorthand written for reading, said in words: abbreviations ("Gov.", "St.", "Ave.", "approx."), times ("1am", "13:00"),
    /// amounts with a scale ("$1M", "3.4K"), ranges ("10-15"), pairs ("24/7"), units, symbols, and roman numerals after names.
    /// Kokoro's own normalization reads these letter by letter, as fractions, or not at all.
    /// An abbreviation's period is kept where it also ends the sentence.
    static func inWords(_ sentence: String) -> String {
        var text = sentence
        text = text.replacing(saint()) { isSaint($0, in: sentence) ? "\($0.1 ?? "")Saint" : String($0.0) }
        text = text.replacing(#/\b(Prof|Gov|Sen|Rep|Gen|Capt|Lt|Col|Sgt|Rev|Pres|Hon|Adm|Maj|Cpl|Fr|Supt)\.\s+(?=[A-Z])/#) {
            "\(titles[String($0.1)] ?? String($0.1)) "
        }
        text = text.replacing(#/\b(Mon|Tues?|Wed|Thu(?:rs?)?|Fri|Sat|Sun)\.(?=,|\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)|\s+\d)/#) {
            days[String($0.1)] ?? String($0.0)
        }
        text = text.replacing(#/([A-Z0-9][\w']*\s+)(Ave|Blvd|Rd|Hwy|Pkwy|Ln)\b(\.)?(\s*$|\s+(?=[A-Z]))?/#) {
            "\($0.1)\(streets[String($0.2)] ?? String($0.2))\(period($0.3, before: $0.4))"
        }
        text = text.replacing(#/\b(Inc|Corp|Bros|Dept|Jr|Sr|approx)\.(\s*$|\s+(?=[A-Z]))?/#) {
            "\(abbreviations[String($0.1)] ?? String($0.1))\(period(".", before: $0.2))"
        }
        text = text.replacing(#/\b(No|no|Fig|fig|Vol|vol|pp)\.\s?(?=\d)/#) { "\(numbered[String($0.1)] ?? String($0.1)) " }

        // Kokoro reads "AM" as a word and "a" as the article, so the meridiem is given as capital letters apart.
        text = text.replacing(#/(^|[^\w:.])(1[0-2]|0?[1-9])(?::([0-5]\d))?\s?([AaPp])(?:\.[Mm](\.)?|[Mm])(?![A-Za-z])(\s*$|\s+(?=[A-Z]))?/#) {
            "\($0.1)\(clock($0.2, $0.3)) \($0.4.uppercased()) M\(period($0.5, before: $0.6))"
        }
        text = text.replacing(#/(^|[^\w:.])(1[3-9]|2[0-3]):([0-5]\d)(?![\d:])/#) {
            "\($0.1)\($0.3 == "00" ? "\($0.2) hundred" : clock($0.2, $0.3))"
        }

        text = text.replacing(#/\$(\d[\d,]*(?:\.\d+)?)(?:([kmbt]|mn|bn|tn)\b|\s?(thousand|million|billion|trillion)\b)/#.ignoresCase()) {
            "\($0.1) \(scales[($0.2 ?? $0.3 ?? "").lowercased()] ?? "") dollars"
        }
        text = text.replacing(#/(\b[A-Za-z]+\s+)?\b(\d[\d,]*(?:\.\d+)?)(K|k|M|B|T|bn|Bn|mn|tn)(?!\w)/#) { match in
            let (_, before, number, scale) = match.output
            let word = before?.trimmingCharacters(in: .whitespaces).lowercased()
            if scale == "B", let word, labeled.contains(word) { return String(match.output.0) }
            // 4K and 8K are resolutions, and a 5K is a race.
            if scale == "K", !number.contains("."), (Int(number) ?? 0) < 10 { return String(match.output.0) }
            return "\(before ?? "")\(number) \(scales[scale.lowercased()] ?? "")"
        }
        text = text.replacing(#/\b(FY|Q[1-4]|H[12])['’]?(\d{2}|\d{4})\b/#) { "\($0.1) \($0.2)" }
        text = text.replacing(#/\b(240|360|480|540|720|1080|1440|2160|4320)([pi])\b/#) { "\($0.1.dropLast(2)) \($0.1.suffix(2)) \($0.2.uppercased())" }
        text = text.replacing(#/\b(\d)['’′](\d{1,2})(?:["”″]|'')?/#) { "\($0.1) foot \($0.2)" }
        text = text.replacing(#/\b(\d+(?:\.\d+)?)\s?(km/h|kmh|kph|mi/h|m/s)\b/#) { "\($0.1) \(unit(speeds[String($0.2)], for: $0.1))" }
        text = text.replacing(#/\b(\d+(?:\.\d+)?)\s?(KB|kB|MB|GB|TB|PB|Kbps|kbps|Mbps|Gbps|Mb|Gb|Tb)\b/#) {
            "\($0.1) \(unit(dataUnits[String($0.2)], for: $0.1))"
        }
        text = text.replacing(#/\b([1-9]\d*)\s?[x×]\s?(\d+)\b/#) { "\($0.1) by \($0.2)" }
        text = text.replacing(#/\b(\d+(?:\.\d+)?)[x×](?!\w)/#) { "\($0.1) times" }
        // Fractions have the smaller number on top, so "24/7", "50/50" and "9/11" are said as pairs.
        text = text.replacing(#/(^|[^\w/.])(\d+)/(\d+)(?![\w/]|\.\d)/#) { match in
            let (_, before, top, bottom) = match.output
            guard let a = Int(top), let b = Int(bottom), a >= b || (a, b) == (9, 11) else { return String(match.output.0) }
            return "\(before)\(top) \(bottom)"
        }
        text = text.replacing(#/(^|[^\w\-])(\d{3})-(\d{4})(?![\w\-])/#) {
            "\($0.1)\($0.2.map(String.init).joined(separator: " ")), \($0.3.map(String.init).joined(separator: " "))"
        }
        // A range rises, and a score like "3-2" is said the same way; other pairs of numbers are left alone.
        text = text.replacing(#/(^|[^\w\-–—/.:,])(\d+(?:\.\d+)?)\s?[-–—]\s?(\d+(?:\.\d+)?)(?![\w\-–—/]|\.\d)/#) { match in
            let (_, before, low, high) = match.output
            guard let a = Double(low), let b = Double(high), b > a || low.count <= 2 && high.count <= 2 else { return String(match.output.0) }
            return "\(before)\(low) to \(high)"
        }

        text = text.replacing(#/[~≈]\s?(?=[\d$£€])/#, with: "about ")
        text = text.replacing(#/(?:>=|≥)\s?(?=[\d$£€])/#, with: "at least ")
        text = text.replacing(#/(?:<=|≤)\s?(?=[\d$£€])/#, with: "at most ")
        text = text.replacing(#/>\s?(?=[\d$£€])/#, with: "more than ")
        text = text.replacing(#/<\s?(?=[\d$£€])/#, with: "less than ")
        text = text.replacing("±", with: " plus or minus ").replacing("²", with: " squared").replacing("³", with: " cubed")
            .replacing("√", with: " square root of ")
        text = text.replacing(#/\bw\/(?!o\b)\s?/#, with: "with ").replacing(#/\bb\/c\b/#, with: "because")
        text = text.replacing(#/(^|[\s(])#(?=\d)/#) { "\($0.1)number " }
        text = text.replacing(#/(^|[\s(])#([A-Za-z]\w*)/#) { "\($0.1)hashtag \($0.2)" }

        text = text.replacing(#/(\b[A-Z][a-z]+\s+)?\b([A-Z][a-z]+)\s+([IVXL]+)\b(?!['’]?\w)/#) { match in
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
        return text.replacing(#/ {2,}/#, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Whether `next` carries on `sentence`, which the tokenizer ended on a title before a name, or a weekday before a date.
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

    /// A unit's name, made plural unless there's exactly one.
    private static func unit(_ name: (String, String)?, for number: Substring) -> String {
        guard let (noun, rest) = name else { return "" }
        return (number == "1" ? noun : noun + "s") + rest
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
        "Adm": "Admiral", "Maj": "Major", "Cpl": "Corporal", "Fr": "Father", "Supt": "Superintendent",
    ]
    private static let days = [
        "Mon": "Monday", "Tue": "Tuesday", "Tues": "Tuesday", "Wed": "Wednesday", "Thu": "Thursday", "Thur": "Thursday",
        "Thurs": "Thursday", "Fri": "Friday", "Sat": "Saturday", "Sun": "Sunday",
    ]
    private static let streets = ["Ave": "Avenue", "Blvd": "Boulevard", "Rd": "Road", "Hwy": "Highway", "Pkwy": "Parkway", "Ln": "Lane"]
    private static let abbreviations = [
        "Inc": "Incorporated", "Corp": "Corporation", "Bros": "Brothers", "Dept": "Department", "Jr": "Junior", "Sr": "Senior",
        "approx": "approximately",
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
