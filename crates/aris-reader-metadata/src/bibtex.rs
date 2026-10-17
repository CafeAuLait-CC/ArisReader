//! BibTeX entries generated from recognised metadata.
//!
//! # What this module deliberately does not do
//!
//! It never invents a field. A missing venue does not become a journal named after the PDF,
//! a missing year does not become the file's creation date, and a missing author list does not
//! become "Anonymous". The entry is a rendering of exactly the values the panel shows, which is
//! why the UI generates its preview through the same function the clipboard and the `.bib`
//! export use.
//!
//! # Escaping
//!
//! Field values are wrapped in braces, so a value may itself contain balanced LaTeX groups
//! (papers with `{BERT}` in the title rely on them to protect capitalisation). Unbalanced braces
//! are escaped, otherwise one malformed title would break every entry in the `.bib` file.
//! LaTeX's special characters (`& % _ # $ ~ ^ \`) are escaped; common Latin diacritics become
//! LaTeX accent commands so classic BibTeX can typeset an author like `Dvorožňák`; characters
//! with no lossless LaTeX spelling (CJK, Greek, emoji) are emitted as UTF-8, which `biber` and
//! `biblatex` accept and classic BibTeX will report rather than silently mangle.
//!
//! URLs are the exception to field escaping: a DOI URL with `\_` in it is not the URL. Only the
//! characters that cannot appear in a braced field are percent-encoded.

/// Which BibTeX entry type the metadata implies.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BibEntryKind {
    /// A journal article (`journal`).
    Article,
    /// A conference/workshop paper (`booktitle`).
    InProceedings,
    /// Anything without a venue, including an arXiv preprint (`howpublished`/`eprint`).
    Misc,
}

impl BibEntryKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Article => "article",
            Self::InProceedings => "inproceedings",
            Self::Misc => "misc",
        }
    }
}

/// The values one entry is generated from.
///
/// These are plain strings, not [`crate::MetadataField`]s, because the panel lets the reader
/// correct every value: provenance decides what the UI shows next to a field, not what BibTeX
/// receives.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BibEntry {
    pub title: String,
    /// One string per author, already split. Empty strings are ignored.
    pub authors: Vec<String>,
    pub venue: String,
    pub year: String,
    pub doi: String,
    pub arxiv_id: String,
}

impl BibEntry {
    pub fn is_empty(&self) -> bool {
        self.title.trim().is_empty()
            && self.authors.iter().all(|author| author.trim().is_empty())
            && self.venue.trim().is_empty()
            && self.year.trim().is_empty()
            && self.doi.trim().is_empty()
            && self.arxiv_id.trim().is_empty()
    }

    /// The entry type the venue implies.
    ///
    /// A venue is what distinguishes a journal article from a conference paper. Without one
    /// there is no honest way to pick `article` or `inproceedings`, so the entry is `misc`;
    /// an arXiv identifier is a preprint, never a proceedings.
    pub fn kind(&self) -> BibEntryKind {
        let venue = self.venue.trim().to_lowercase();
        if venue.is_empty() || venue.starts_with("arxiv") || venue.contains("preprint") {
            return BibEntryKind::Misc;
        }
        if looks_like_conference(&venue) {
            BibEntryKind::InProceedings
        } else {
            BibEntryKind::Article
        }
    }

    /// A citation key derived from first author, year and the first significant title word.
    pub fn key(&self) -> String {
        let author = self
            .authors
            .iter()
            .map(|author| first_author_surname(author))
            .find(|surname| !surname.is_empty())
            .unwrap_or_default();
        let year = first_year(&self.year).unwrap_or_default();
        let word = first_title_word(&self.title);
        let key = format!("{}{}{}", key_component(&author), year, key_component(&word));
        if key.is_empty() {
            "untitled".to_string()
        } else {
            key
        }
    }

    /// The complete entry, with a trailing newline.
    pub fn to_bibtex(&self) -> String {
        let kind = self.kind();
        let mut fields: Vec<(&str, String)> = Vec::new();

        let authors = self
            .authors
            .iter()
            .map(|author| author.trim())
            .filter(|author| !author.is_empty())
            .map(escape_value)
            .collect::<Vec<_>>();
        if !authors.is_empty() {
            fields.push(("author", authors.join(" and ")));
        }
        if !self.title.trim().is_empty() {
            fields.push(("title", escape_value(self.title.trim())));
        }
        match kind {
            BibEntryKind::Article => {
                if !self.venue.trim().is_empty() {
                    fields.push(("journal", escape_value(self.venue.trim())));
                }
            }
            BibEntryKind::InProceedings => {
                if !self.venue.trim().is_empty() {
                    fields.push(("booktitle", escape_value(self.venue.trim())));
                }
            }
            BibEntryKind::Misc => {
                if !self.arxiv_id.trim().is_empty() {
                    let id = self.arxiv_id.trim();
                    fields.push((
                        "howpublished",
                        escape_value(&format!("arXiv preprint arXiv:{id}")),
                    ));
                    fields.push(("eprint", escape_value(id)));
                    fields.push(("archivePrefix", "arXiv".to_string()));
                }
            }
        }
        if let Some(year) = first_year(&self.year) {
            fields.push(("year", year));
        } else if !self.year.trim().is_empty() {
            // A value like "in press" is still what the reader typed; do not drop it.
            fields.push(("year", escape_value(self.year.trim())));
        }
        let doi = normalise_doi(&self.doi);
        if let Some(doi) = &doi {
            fields.push(("doi", escape_value(doi)));
        }
        if let Some(url) = self.url(&doi) {
            fields.push(("url", url));
        }

        let key = self.key();
        let body = fields
            .iter()
            .map(|(name, value)| format!("  {name} = {{{value}}}"))
            .collect::<Vec<_>>()
            .join(",\n");
        if body.is_empty() {
            format!("@{}{{{}\n}}\n", kind.as_str(), key)
        } else {
            format!("@{}{{{},\n{body}\n}}\n", kind.as_str(), key)
        }
    }

    fn url(&self, doi: &Option<String>) -> Option<String> {
        let arxiv = self.arxiv_id.trim();
        if let Some(doi) = doi {
            return Some(format!("https://doi.org/{}", escape_url(doi)));
        }
        if !arxiv.is_empty() {
            return Some(format!("https://arxiv.org/abs/{}", escape_url(arxiv)));
        }
        None
    }
}

/// The entry an empty [`BibEntry`] produces, for callers that want a placeholder preview.
pub fn generate(entry: &BibEntry) -> String {
    entry.to_bibtex()
}

fn looks_like_conference(venue: &str) -> bool {
    const CONFERENCE_WORDS: &[&str] = &[
        "conference",
        "proceedings",
        "proc.",
        "workshop",
        "symposium",
        "colloquium",
        "meeting",
        "summit",
        "congress",
        "cvpr",
        "iccv",
        "eccv",
        "wacv",
        "bmvc",
        "accv",
        "3dv",
        "neurips",
        "nips",
        "icml",
        "iclr",
        "aaai",
        "ijcai",
        "acl",
        "emnlp",
        "naacl",
        "coling",
        "conll",
        "siggraph",
        "chi",
        "uist",
        "kdd",
        "www",
        "icra",
        "iros",
        "miccai",
        "interspeech",
        "corl",
        "rss",
        "usenix",
        "vis",
        "mm",
        "international conference",
        "neural information processing systems",
        "computer vision and pattern recognition",
        "learning representations",
        "association for computational linguistics",
    ];
    CONFERENCE_WORDS.iter().any(|word| venue.contains(word))
}

fn normalise_doi(value: &str) -> Option<String> {
    let mut doi = value.trim();
    for prefix in [
        "https://doi.org/",
        "http://doi.org/",
        "https://dx.doi.org/",
        "http://dx.doi.org/",
        "doi:",
        "DOI:",
    ] {
        if let Some(rest) = doi.strip_prefix(prefix) {
            doi = rest.trim();
            break;
        }
    }
    if doi.starts_with("10.") && doi.len() > 6 {
        Some(doi.to_string())
    } else {
        None
    }
}

fn first_year(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    for window in bytes.windows(4) {
        if window.iter().all(u8::is_ascii_digit) {
            let text = std::str::from_utf8(window).ok()?;
            let year = text.parse::<u32>().ok()?;
            if (1900..=2099).contains(&year) {
                return Some(text.to_string());
            }
        }
    }
    None
}

fn first_author_surname(author: &str) -> String {
    let mut author = author.trim();
    for suffix in ["et al.", "et al", "and others"] {
        if let Some(stripped) = author.strip_suffix(suffix) {
            author = stripped.trim();
        }
    }
    if author.is_empty() {
        return String::new();
    }
    // "Last, First" and "Last, F." name the surname before the comma. An author list has
    // already been split by the recogniser, so this comma is part of one person's name.
    if let Some((last, _)) = author.split_once(',') {
        return last.trim().to_string();
    }
    author
        .split_whitespace()
        .last()
        .unwrap_or(author)
        .to_string()
}

fn first_title_word(title: &str) -> String {
    const STOP_WORDS: &[&str] = &[
        "a", "an", "the", "on", "of", "for", "to", "in", "and", "with", "from", "by", "is", "are",
        "at", "as", "towards", "toward", "into", "using", "via", "do", "does", "can", "we", "how",
        "what", "why", "when",
    ];
    let words = title
        .split_whitespace()
        .map(|word| {
            word.trim_matches(|character: char| !character.is_alphanumeric())
                .to_string()
        })
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>();
    for word in &words {
        let lower = word.to_lowercase();
        if !STOP_WORDS.contains(&lower.as_str()) && word.chars().count() >= 3 {
            return word.clone();
        }
    }
    words.first().cloned().unwrap_or_default()
}

fn key_component(value: &str) -> String {
    let mut output = String::new();
    for character in value.chars() {
        if character.is_ascii_alphanumeric() {
            output.push(character.to_ascii_lowercase());
        } else if let Some(fold) = ascii_fold(character) {
            output.extend(fold.chars().filter(char::is_ascii_alphanumeric));
        }
    }
    output
}

/// The ASCII letters a Latin character stands for, for citation keys only.
fn ascii_fold(character: char) -> Option<&'static str> {
    let lower = character.to_lowercase().next()?;
    Some(match lower {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => "a",
        'ç' | 'ć' | 'ĉ' | 'ċ' | 'č' => "c",
        'ď' | 'đ' => "d",
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => "e",
        'ĝ' | 'ğ' | 'ġ' | 'ģ' => "g",
        'ĥ' | 'ħ' => "h",
        'ì' | 'í' | 'î' | 'ï' | 'ĩ' | 'ī' | 'ĭ' | 'į' | 'ı' => "i",
        'ĵ' => "j",
        'ķ' => "k",
        'ĺ' | 'ļ' | 'ľ' | 'ŀ' | 'ł' => "l",
        'ñ' | 'ń' | 'ņ' | 'ň' | 'ŉ' => "n",
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ŏ' | 'ő' => "o",
        'ŕ' | 'ŗ' | 'ř' => "r",
        'ś' | 'ŝ' | 'ş' | 'š' => "s",
        'ţ' | 'ť' | 'ŧ' => "t",
        'ù' | 'ú' | 'û' | 'ü' | 'ũ' | 'ū' | 'ŭ' | 'ů' | 'ű' | 'ų' => "u",
        'ŵ' => "w",
        'ý' | 'ÿ' | 'ŷ' => "y",
        'ź' | 'ż' | 'ž' => "z",
        'æ' => "ae",
        'œ' => "oe",
        'ß' => "ss",
        _ => return None,
    })
}

/// Escapes one BibTeX field value (without the surrounding braces).
pub fn escape_value(value: &str) -> String {
    let balanced = braces_are_balanced(value);
    let collapsed = value.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut output = String::with_capacity(collapsed.len());
    for character in collapsed.chars() {
        match character {
            '\\' => output.push_str(r"\textbackslash{}"),
            '&' => output.push_str(r"\&"),
            '%' => output.push_str(r"\%"),
            '_' => output.push_str(r"\_"),
            '#' => output.push_str(r"\#"),
            '$' => output.push_str(r"\$"),
            '~' => output.push_str(r"\textasciitilde{}"),
            '^' => output.push_str(r"\textasciicircum{}"),
            '{' if balanced => output.push('{'),
            '}' if balanced => output.push('}'),
            '{' => output.push_str(r"\{"),
            '}' => output.push_str(r"\}"),
            character => match latex_character(character) {
                Some(escaped) => output.push_str(escaped),
                None => output.push(character),
            },
        }
    }
    output
}

fn braces_are_balanced(value: &str) -> bool {
    let mut depth = 0i32;
    for character in value.chars() {
        match character {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth < 0 {
                    return false;
                }
            }
            _ => {}
        }
    }
    depth == 0
}

/// URL fields are not LaTeX text: only characters that cannot sit inside `{...}` are encoded.
fn escape_url(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '{' => output.push_str("%7B"),
            '}' => output.push_str("%7D"),
            '\\' => output.push_str("%5C"),
            character if character.is_whitespace() => output.push_str("%20"),
            character => output.push(character),
        }
    }
    output
}

/// LaTeX spelling for a Latin character with a diacritic.
///
/// The table covers the characters that actually appear in author names in this corpus. A
/// character outside it is emitted verbatim rather than approximated under the wrong accent.
fn latex_character(character: char) -> Option<&'static str> {
    Some(match character {
        'À' => r"\`A",
        'Á' => r"\'A",
        'Â' => r"\^A",
        'Ã' => r"\~A",
        'Ä' => r#"\"A"#,
        'Å' => r"\AA{}",
        'Æ' => r"\AE{}",
        'Ç' => r"\c{C}",
        'È' => r"\`E",
        'É' => r"\'E",
        'Ê' => r"\^E",
        'Ë' => r#"\"E"#,
        'Ì' => r"\`I",
        'Í' => r"\'I",
        'Î' => r"\^I",
        'Ï' => r#"\"I"#,
        'Ð' => r"\DH{}",
        'Ñ' => r"\~N",
        'Ò' => r"\`O",
        'Ó' => r"\'O",
        'Ô' => r"\^O",
        'Õ' => r"\~O",
        'Ö' => r#"\"O"#,
        'Ø' => r"\O{}",
        'Ù' => r"\`U",
        'Ú' => r"\'U",
        'Û' => r"\^U",
        'Ü' => r#"\"U"#,
        'Ý' => r"\'Y",
        'Þ' => r"\TH{}",
        'ß' => r"\ss{}",
        'à' => r"\`a",
        'á' => r"\'a",
        'â' => r"\^a",
        'ã' => r"\~a",
        'ä' => r#"\"a"#,
        'å' => r"\aa{}",
        'æ' => r"\ae{}",
        'ç' => r"\c{c}",
        'è' => r"\`e",
        'é' => r"\'e",
        'ê' => r"\^e",
        'ë' => r#"\"e"#,
        'ì' => r"\`i",
        'í' => r"\'i",
        'î' => r"\^i",
        'ï' => r#"\"i"#,
        'ð' => r"\dh{}",
        'ñ' => r"\~n",
        'ò' => r"\`o",
        'ó' => r"\'o",
        'ô' => r"\^o",
        'õ' => r"\~o",
        'ö' => r#"\"o"#,
        'ø' => r"\o{}",
        'ù' => r"\`u",
        'ú' => r"\'u",
        'û' => r"\^u",
        'ü' => r#"\"u"#,
        'ý' => r"\'y",
        'þ' => r"\th{}",
        'ÿ' => r#"\"y"#,
        'Ā' | 'ā' => r"\=a",
        'Ą' | 'ą' => r"\k{a}",
        'Ć' | 'ć' => r"\'c",
        'Č' | 'č' => r"\v{c}",
        'Ď' | 'ď' => r"\v{d}",
        'Đ' | 'đ' => r"\dj{}",
        'Ē' | 'ē' => r"\=e",
        'Ę' | 'ę' => r"\k{e}",
        'Ě' | 'ě' => r"\v{e}",
        'Ğ' | 'ğ' => r"\u{g}",
        'Ī' | 'ī' => r"\=i",
        'Į' | 'į' => r"\k{i}",
        'Ł' | 'ł' => r"\L{}",
        'Ń' | 'ń' => r"\'n",
        'Ņ' | 'ņ' => r"\c{n}",
        'Ň' | 'ň' => r"\v{n}",
        'Ō' | 'ō' => r"\=o",
        'Ő' | 'ő' => r"\H{o}",
        'Œ' | 'œ' => r"\oe{}",
        'Ř' | 'ř' => r"\v{r}",
        'Ś' | 'ś' => r"\'s",
        'Ş' | 'ş' => r"\c{s}",
        'Š' | 'š' => r"\v{s}",
        'Ţ' | 'ţ' => r"\c{t}",
        'Ť' | 'ť' => r"\v{t}",
        'Ū' | 'ū' => r"\=u",
        'Ů' | 'ů' => r"\r{u}",
        'Ű' | 'ű' => r"\H{u}",
        'Ź' | 'ź' => r"\'z",
        'Ż' | 'ż' => r"\.z",
        'Ž' | 'ž' => r"\v{z}",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A tiny BibTeX reader used only by the tests: it checks that a generated entry has the
    /// structure BibTeX expects and recovers every field value without any parser dependency.
    struct ParsedEntry {
        kind: String,
        key: String,
        fields: Vec<(String, String)>,
    }

    fn parse(entry: &str) -> ParsedEntry {
        let text = entry.trim();
        assert!(text.starts_with('@'), "entry must start with @: {text}");
        let open = text.find('{').expect("opening brace");
        let kind = text[1..open].to_string();
        let mut cursor = open + 1;
        let comma = text[cursor..]
            .find(',')
            .map(|offset| cursor + offset)
            .unwrap_or_else(|| panic!("entry has no field separator: {text}"));
        let key = text[cursor..comma].trim().to_string();
        cursor = comma + 1;

        let bytes = text.as_bytes();
        let mut fields = Vec::new();
        loop {
            while cursor < bytes.len()
                && (bytes[cursor].is_ascii_whitespace() || bytes[cursor] == b',')
            {
                cursor += 1;
            }
            if cursor >= bytes.len() {
                break;
            }
            if bytes[cursor] == b'}' {
                break;
            }
            let name_start = cursor;
            while cursor < bytes.len()
                && (bytes[cursor].is_ascii_alphanumeric() || bytes[cursor] == b'_')
            {
                cursor += 1;
            }
            let name = text[name_start..cursor].to_string();
            while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
                cursor += 1;
            }
            assert_eq!(bytes[cursor], b'=', "field {name} has no '='");
            cursor += 1;
            while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
                cursor += 1;
            }
            assert_eq!(bytes[cursor], b'{', "field {name} is not braced");
            cursor += 1;
            let value_start = cursor;
            let mut depth = 1usize;
            while cursor < bytes.len() && depth > 0 {
                match bytes[cursor] {
                    b'\\' => cursor += 2,
                    b'{' => {
                        depth += 1;
                        cursor += 1;
                    }
                    b'}' => {
                        depth -= 1;
                        cursor += 1;
                    }
                    _ => cursor += 1,
                }
            }
            assert_eq!(depth, 0, "field {name} has unbalanced braces");
            let value = text[value_start..cursor - 1].to_string();
            fields.push((name, value));
        }
        assert!(text.ends_with('}'), "entry must close with a brace: {text}");
        ParsedEntry { kind, key, fields }
    }

    /// Brace balance as BibTeX sees it: `\{` and `\}` are literal characters, not groups.
    fn balanced_bibtex(value: &str) -> bool {
        let mut depth = 0i32;
        let mut escaped = false;
        for character in value.chars() {
            if escaped {
                escaped = false;
                continue;
            }
            match character {
                '\\' => escaped = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if depth < 0 {
                        return false;
                    }
                }
                _ => {}
            }
        }
        depth == 0
    }

    fn field<'a>(parsed: &'a ParsedEntry, name: &str) -> Option<&'a str> {
        parsed
            .fields
            .iter()
            .find(|(field, _)| field == name)
            .map(|(_, value)| value.as_str())
    }

    fn entry() -> BibEntry {
        BibEntry {
            title: "Attention Is All You Need".to_string(),
            authors: vec!["Ashish Vaswani".into(), "Noam Shazeer".into()],
            venue: "Advances in Neural Information Processing Systems".into(),
            year: "2017".into(),
            doi: "10.5555/3295222.3295349".into(),
            arxiv_id: "1706.03762".into(),
        }
    }

    #[test]
    fn a_conference_venue_generates_an_inproceedings_entry() {
        let text = entry().to_bibtex();
        let parsed = parse(&text);
        assert_eq!(parsed.kind, "inproceedings");
        assert_eq!(parsed.key, "vaswani2017attention");
        assert_eq!(
            field(&parsed, "booktitle"),
            Some("Advances in Neural Information Processing Systems")
        );
        assert_eq!(
            field(&parsed, "author"),
            Some("Ashish Vaswani and Noam Shazeer")
        );
        assert_eq!(
            field(&parsed, "url"),
            Some("https://doi.org/10.5555/3295222.3295349")
        );
        assert!(field(&parsed, "journal").is_none());
    }

    #[test]
    fn a_journal_venue_generates_an_article_and_the_arxiv_fallbacks_are_misc() {
        let mut journal = entry();
        journal.venue = "Journal of Testing".into();
        let parsed = parse(&journal.to_bibtex());
        assert_eq!(parsed.kind, "article");
        assert_eq!(field(&parsed, "journal"), Some("Journal of Testing"));

        let mut preprint = entry();
        preprint.venue.clear();
        preprint.doi.clear();
        let text = preprint.to_bibtex();
        let parsed = parse(&text);
        assert_eq!(parsed.kind, "misc");
        assert_eq!(
            field(&parsed, "howpublished"),
            Some("arXiv preprint arXiv:1706.03762")
        );
        assert_eq!(field(&parsed, "eprint"), Some("1706.03762"));
        assert_eq!(field(&parsed, "archivePrefix"), Some("arXiv"));
        assert_eq!(
            field(&parsed, "url"),
            Some("https://arxiv.org/abs/1706.03762")
        );
    }

    #[test]
    fn empty_fields_are_not_invented() {
        let entry = BibEntry {
            title: "Only a title".into(),
            ..BibEntry::default()
        };
        let text = entry.to_bibtex();
        let parsed = parse(&text);
        assert_eq!(parsed.kind, "misc");
        assert_eq!(parsed.fields.len(), 1);
        assert_eq!(field(&parsed, "title"), Some("Only a title"));
        assert_eq!(entry.key(), "only");
    }

    #[test]
    fn special_characters_are_escaped_and_balanced_groups_are_preserved() {
        let entry = BibEntry {
            title: "{BERT} & 100% of a_b #1 $x$ ~ ^ \\ {unclosed".into(),
            authors: vec!["A".into()],
            year: "2024".into(),
            ..BibEntry::default()
        };
        let text = entry.to_bibtex();
        let parsed = parse(&text);
        assert_eq!(
            field(&parsed, "title"),
            Some(
                r"\{BERT\} \& 100\% of a\_b \#1 \$x\$ \textasciitilde{} \textasciicircum{} \textbackslash{} \{unclosed"
            )
        );
        // The malformed group was escaped, so the entry's own braces still balance.
        assert_eq!(parsed.fields.len(), 3);
    }

    #[test]
    fn accented_author_names_take_their_latex_spelling_and_keys_stay_ascii() {
        let entry = BibEntry {
            title: "Example".into(),
            authors: vec!["Dvorožňák, Marek".into(), "Łukasz Müller".into()],
            year: "2017".into(),
            ..BibEntry::default()
        };
        let parsed = parse(&entry.to_bibtex());
        assert_eq!(
            field(&parsed, "author"),
            Some(r#"Dvoro\v{z}\v{n}\'ak, Marek and \L{}ukasz M\"uller"#)
        );
        assert_eq!(entry.key(), "dvoroznak2017example");
    }

    #[test]
    fn urls_inside_a_doi_are_not_latex_escaped() {
        let mut entry = entry();
        entry.doi = "10.1000/a_b{c}".into();
        let parsed = parse(&entry.to_bibtex());
        assert_eq!(field(&parsed, "doi"), Some(r"10.1000/a\_b{c}"));
        assert_eq!(
            field(&parsed, "url"),
            Some("https://doi.org/10.1000/a_b%7Bc%7D")
        );
    }

    #[test]
    fn the_key_uses_the_first_author_year_and_title_word() {
        let mut entry = entry();
        assert_eq!(entry.key(), "vaswani2017attention");
        entry.title = "The {BERT} Model".into();
        assert_eq!(entry.key(), "vaswani2017bert");
        entry.authors = vec!["Vaswani, Ashish".into()];
        assert_eq!(entry.key(), "vaswani2017bert");
    }

    #[test]
    fn every_generated_entry_is_balanced_even_for_hostile_input() {
        for title in [
            "Plain",
            "A & B",
            "{unbalanced",
            "unbalanced}",
            "100%",
            "\\",
            "{a} {b}",
        ] {
            let entry = BibEntry {
                title: title.into(),
                authors: vec!["Author, A.".into()],
                venue: "Journal of {Tests}".into(),
                year: "2020".into(),
                ..BibEntry::default()
            };
            let text = entry.to_bibtex();
            parse(&text);
            assert!(
                balanced_bibtex(&text),
                "entry braces are unbalanced: {text}"
            );
        }
    }
}
