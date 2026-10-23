//! A deliberately small XML reader for XFA packets.
//!
//! XFA is XML, but the reader only needs a tree, attributes and text. A general XML crate
//! would add a dependency and a schema surface for no benefit here; this parser handles the
//! constructs LiveCycle emits (declarations, comments, CDATA, namespaces, entities, rich-text
//! XHTML) and tolerates a malformed packet by keeping the elements it did read. It never
//! resolves external entities and never executes anything.

use std::collections::BTreeMap;

/// Maximum nesting depth accepted. XFA trees are shallow (about a dozen levels); a deep
/// document from a damaged file must not overflow the stack in the recursive helpers.
const MAX_DEPTH: usize = 512;

/// One XML element. Namespace prefixes are stripped from element and attribute names, because
/// XFA uses several namespaces for the same vocabulary (`xfa:data`, `xfa:datasets`, …).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Element {
    pub name: String,
    pub attributes: BTreeMap<String, String>,
    pub children: Vec<Node>,
}

/// A child node: an element or a run of text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Node {
    Element(Element),
    Text(String),
}

impl Element {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            attributes: BTreeMap::new(),
            children: Vec::new(),
        }
    }

    /// First child element with `name`, case-insensitively (HTML is not always lower-case).
    pub fn child(&self, name: &str) -> Option<&Element> {
        self.children.iter().find_map(|node| match node {
            Node::Element(element) if element.name.eq_ignore_ascii_case(name) => Some(element),
            _ => None,
        })
    }

    /// Every child element with `name`.
    pub fn children_named<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a Element> {
        self.children.iter().filter_map(move |node| match node {
            Node::Element(element) if element.name.eq_ignore_ascii_case(name) => Some(element),
            _ => None,
        })
    }

    /// Direct child elements.
    pub fn elements(&self) -> impl Iterator<Item = &Element> {
        self.children.iter().filter_map(|node| match node {
            Node::Element(element) => Some(element),
            Node::Text(_) => None,
        })
    }

    /// An attribute, case-insensitively on the key.
    pub fn attribute(&self, name: &str) -> Option<&str> {
        self.attributes
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    /// Concatenated text of this element and all descendants, with no separator.
    pub fn text(&self) -> String {
        let mut out = String::new();
        self.collect_text(&mut out);
        out
    }

    fn collect_text(&self, out: &mut String) {
        for child in &self.children {
            match child {
                Node::Text(text) => out.push_str(text),
                Node::Element(element) => element.collect_text(out),
            }
        }
    }

    /// Direct text only (the text between this element's own tags, excluding descendants).
    pub fn direct_text(&self) -> String {
        let mut out = String::new();
        for child in &self.children {
            if let Node::Text(text) = child {
                out.push_str(text);
            }
        }
        out
    }

    /// Text of the first descendant named `name`.
    pub fn descendant_text(&self, name: &str) -> Option<String> {
        if self.name.eq_ignore_ascii_case(name) {
            return Some(self.text());
        }
        for child in self.elements() {
            if let Some(text) = child.descendant_text(name) {
                return Some(text);
            }
        }
        None
    }

    /// Depth-first search for the first element named `name`.
    pub fn find(&self, name: &str) -> Option<&Element> {
        if self.name.eq_ignore_ascii_case(name) {
            return Some(self);
        }
        for child in self.elements() {
            if let Some(found) = child.find(name) {
                return Some(found);
            }
        }
        None
    }

    /// All descendant elements named `name`, in document order.
    pub fn find_all<'a>(&'a self, name: &'a str, out: &mut Vec<&'a Element>) {
        if self.name.eq_ignore_ascii_case(name) {
            out.push(self);
        }
        for child in self.elements() {
            child.find_all(name, out);
        }
    }
}

/// Parse a document and return its root element. Text outside the root is ignored.
pub fn parse(input: &str) -> Option<Element> {
    let mut parser = Parser { input, position: 0 };
    parser.parse_document()
}

struct Parser<'a> {
    input: &'a str,
    position: usize,
}

impl Parser<'_> {
    fn parse_document(&mut self) -> Option<Element> {
        let mut stack: Vec<Element> = Vec::new();
        let mut root: Option<Element> = None;

        while self.position < self.input.len() {
            if self.starts_with("<!--") {
                self.skip_until("-->");
                continue;
            }
            if self.starts_with("<![CDATA[") {
                let content = self.take_until("]]>").unwrap_or_default();
                Self::push_text(&mut stack, content);
                continue;
            }
            if self.starts_with("<?") {
                self.skip_until("?>");
                continue;
            }
            if self.starts_with("<!") {
                // DOCTYPE and other declarations: skip to the matching '>'. XFA does not use
                // internal subsets in the packets we read.
                self.skip_until(">");
                continue;
            }
            if self.starts_with("</") {
                self.position += 2;
                let name = self.take_name();
                self.skip_until(">");
                if let Some(element) = pop_to(&mut stack, &name) {
                    Self::attach(&mut stack, &mut root, element);
                }
                continue;
            }
            if self.starts_with("<") {
                self.position += 1;
                let name = self.take_name();
                if name.is_empty() {
                    // A stray '<': treat it as text so the rest of the packet is not lost.
                    Self::push_text(&mut stack, "<");
                    continue;
                }
                let mut element = Element::new(name);
                let self_closing = self.parse_attributes(&mut element);
                if self_closing {
                    Self::attach(&mut stack, &mut root, element);
                } else if stack.len() < MAX_DEPTH {
                    stack.push(element);
                } else {
                    // At the depth limit the element is flattened into text.
                    self.skip_until(">");
                }
                continue;
            }
            let text = self.take_text();
            Self::push_text(&mut stack, text);
        }

        // A truncated packet loses its closing tags; keep the elements that were opened.
        while let Some(element) = stack.pop() {
            Self::attach(&mut stack, &mut root, element);
        }
        root
    }

    fn attach(stack: &mut [Element], root: &mut Option<Element>, element: Element) {
        match stack.last_mut() {
            Some(parent) => parent.children.push(Node::Element(element)),
            None => {
                if root.is_none() {
                    *root = Some(element);
                }
            }
        }
    }

    fn push_text(stack: &mut [Element], text: &str) {
        if text.is_empty() {
            return;
        }
        if let Some(parent) = stack.last_mut() {
            parent.children.push(Node::Text(decode_entities(text)));
        }
    }

    /// Parses attributes after the element name. Returns true for a self-closing tag.
    fn parse_attributes(&mut self, element: &mut Element) -> bool {
        loop {
            self.skip_whitespace();
            if self.position >= self.input.len() {
                return false;
            }
            if self.starts_with("/>") {
                self.position += 2;
                return true;
            }
            if self.starts_with(">") {
                self.position += 1;
                return false;
            }
            let name = self.take_attribute_name();
            if name.is_empty() {
                // Not an attribute; step over the character so the loop always advances.
                self.position += 1;
                continue;
            }
            self.skip_whitespace();
            if !self.starts_with("=") {
                element
                    .attributes
                    .insert(local_name(&name).to_string(), String::new());
                continue;
            }
            self.position += 1;
            self.skip_whitespace();
            let value = if self.starts_with("\"") || self.starts_with("'") {
                let quote = self.input[self.position..].chars().next().unwrap_or('"');
                self.position += quote.len_utf8();
                let value = self
                    .take_until(&quote.to_string())
                    .unwrap_or_default()
                    .to_string();
                self.position = (self.position + quote.len_utf8()).min(self.input.len());
                value
            } else {
                self.take_unquoted_attribute()
            };
            element
                .attributes
                .insert(local_name(&name).to_string(), decode_entities(&value));
        }
    }

    fn take_name(&mut self) -> String {
        let start = self.position;
        let mut end = start;
        for (offset, character) in self.input[start..].char_indices() {
            if character.is_whitespace() || matches!(character, '>' | '/' | '=' | '<') {
                break;
            }
            end = start + offset + character.len_utf8();
        }
        self.position = end;
        local_name(&self.input[start..end]).to_string()
    }

    fn take_attribute_name(&mut self) -> String {
        let start = self.position;
        let mut end = start;
        for (offset, character) in self.input[start..].char_indices() {
            if character.is_whitespace() || matches!(character, '=' | '>' | '/' | '<') {
                break;
            }
            end = start + offset + character.len_utf8();
        }
        self.position = end;
        self.input[start..end].to_string()
    }

    fn take_unquoted_attribute(&mut self) -> String {
        let start = self.position;
        let mut end = start;
        for (offset, character) in self.input[start..].char_indices() {
            if character.is_whitespace() || matches!(character, '>' | '/') {
                break;
            }
            end = start + offset + character.len_utf8();
        }
        self.position = end;
        self.input[start..end].to_string()
    }

    fn take_text(&mut self) -> &str {
        let start = self.position;
        let mut end = self.input.len();
        for (offset, character) in self.input[start..].char_indices() {
            if character == '<' {
                end = start + offset;
                break;
            }
        }
        self.position = end;
        &self.input[start..end]
    }

    fn take_until(&mut self, delimiter: &str) -> Option<&str> {
        let start = self.position;
        let end = self.input[start..].find(delimiter)? + start;
        self.position = end;
        Some(&self.input[start..end])
    }

    fn skip_until(&mut self, delimiter: &str) {
        if let Some(end) = self.input[self.position..].find(delimiter) {
            self.position += end + delimiter.len();
        } else {
            self.position = self.input.len();
        }
    }

    fn skip_whitespace(&mut self) {
        let start = self.position;
        let mut end = start;
        for (offset, character) in self.input[start..].char_indices() {
            if !character.is_whitespace() {
                break;
            }
            end = start + offset + character.len_utf8();
        }
        self.position = end;
    }

    fn starts_with(&self, value: &str) -> bool {
        self.input[self.position..].starts_with(value)
    }
}

fn pop_to(stack: &mut Vec<Element>, name: &str) -> Option<Element> {
    while let Some(element) = stack.pop() {
        if element.name.eq_ignore_ascii_case(name) {
            return Some(element);
        }
        // A mismatched end tag: keep the element as a child of its opener rather than
        // dropping content. Closing tags in damaged packets are common.
        if let Some(parent) = stack.last_mut() {
            parent.children.push(Node::Element(element));
        } else {
            return Some(element);
        }
    }
    None
}

/// The part after the last `:`; XFA repeats the same vocabulary across namespaces.
fn local_name(name: &str) -> &str {
    name.rsplit(':').next().unwrap_or(name)
}

fn decode_entities(text: &str) -> String {
    if !text.contains('&') {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(index) = rest.find('&') {
        out.push_str(&rest[..index]);
        let after = &rest[index + 1..];
        let Some(end) = after.find(';') else {
            out.push_str(&rest[index..]);
            return out;
        };
        let entity = &after[..end];
        let decoded = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" => Some('\u{a0}'),
            _ if entity.starts_with("#x") || entity.starts_with("#X") => {
                u32::from_str_radix(&entity[2..], 16)
                    .ok()
                    .and_then(char::from_u32)
            }
            _ if entity.starts_with('#') => {
                entity[1..].parse::<u32>().ok().and_then(char::from_u32)
            }
            _ => None,
        };
        match decoded {
            Some(character) => out.push(character),
            None => {
                out.push('&');
                out.push_str(entity);
                out.push(';');
            }
        }
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_namespaces_attributes_and_text() {
        let root = parse(
            r#"<?xml version="1.0"?><xdp:xdp xmlns:xdp="x"><template><subform name="form1" w="200.66mm"><draw name="d"><value><text>a &amp; b</text></value></draw></subform></template></xdp:xdp>"#,
        )
        .expect("root");
        assert_eq!(root.name, "xdp");
        let subform = root.find("subform").expect("subform");
        assert_eq!(subform.attribute("name"), Some("form1"));
        assert_eq!(subform.attribute("w"), Some("200.66mm"));
        assert_eq!(root.descendant_text("text").as_deref(), Some("a & b"));
    }

    #[test]
    fn keeps_rich_text_paragraph_order() {
        let root = parse(
            r#"<exData contentType="text/html"><body><p>one</p><p>two <span>bold</span></p></body></exData>"#,
        )
        .expect("root");
        let body = root.child("body").expect("body");
        let paragraphs: Vec<String> = body.children_named("p").map(Element::text).collect();
        assert_eq!(paragraphs, ["one", "two bold"]);
    }

    #[test]
    fn decodes_numeric_and_named_entities() {
        let root = parse("<a>&#65;&#x42;&nbsp;&amp;</a>").expect("root");
        assert_eq!(root.text(), "AB\u{a0}&");
    }

    #[test]
    fn tolerates_truncated_and_mismatched_tags() {
        let root = parse("<a><b>text</a>").expect("root");
        assert_eq!(root.text(), "text");
    }
}
