//! The XFA datasets packet: the values the form was saved with, plus the LOV (list of values)
//! tables the template's `bindItems` references.
//!
//! A blank form often has no visible values at all; the default country is a code (`511`) that
//! only becomes text through a LOV table. Resolution therefore runs through the same chain a
//! viewer uses: dataset value → field items → LOV label, then the template default as the last
//! resort.

use crate::error::{Result, XfaError};
use crate::model::{FieldInfo, FieldType, RichParagraph};
use crate::units::normalise_space;
use crate::xml::{Element, parse as parse_xml};
use std::collections::{BTreeMap, HashMap};

/// One node of the `xfa:data` tree.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DataNode {
    pub name: String,
    pub attributes: BTreeMap<String, String>,
    pub text: String,
    pub children: Vec<DataNode>,
}

impl DataNode {
    fn from_element(element: &Element) -> Self {
        let text = normalise_space(&element.direct_text()).trim().to_string();
        Self {
            name: element.name.clone(),
            attributes: element.attributes.clone(),
            text,
            children: element.elements().map(Self::from_element).collect(),
        }
    }
}

/// One entry of a LOV list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LovEntry {
    pub label: String,
    pub value: String,
}

/// The dataset packet, indexed for lookup.
#[derive(Clone, Debug, Default)]
pub struct DataSet {
    /// The `data` root (usually `form1`).
    pub root: Option<DataNode>,
    /// Non-empty leaf values, with their slash-separated paths, for the report.
    pub values: Vec<(String, String)>,
    /// LOV lists keyed by both the list name (`CountryList`) and the entry name (`Country`).
    pub lov: BTreeMap<String, Vec<LovEntry>>,
    /// Number of top-level LOV lists (aliases are not counted).
    pub lov_table_count: usize,
    pub lov_entries: usize,
    /// Path → text, with each repeated sibling represented by its occurrence index.
    by_path: HashMap<String, String>,
    /// Leaf name → every value with that name (used only when a path does not match).
    by_leaf: HashMap<String, Vec<String>>,
    pub warnings: Vec<String>,
}

impl DataSet {
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        let text = String::from_utf8_lossy(bytes);
        let document = parse_xml(&text)
            .ok_or_else(|| XfaError::Malformed("the datasets packet is not XML".to_string()))?;
        let datasets = if document.name.eq_ignore_ascii_case("datasets") {
            document
        } else {
            document.find("datasets").cloned().ok_or_else(|| {
                XfaError::Malformed("the packet has no <datasets> element".to_string())
            })?
        };
        let mut dataset = Self::default();
        if let Some(data) = datasets.child("data") {
            // LiveCycle wraps the record in `<data>`; the template's paths start at the record
            // (`form1`). Use the single child as the root so a template path and a data path
            // have the same first component. A data element with several children keeps the
            // `data` root, and the unique-leaf fallback still resolves those forms.
            let only_child = {
                let mut children = data.elements();
                match (children.next(), children.next()) {
                    (Some(child), None) => Some(child),
                    _ => None,
                }
            };
            let root = DataNode::from_element(only_child.unwrap_or(data));
            dataset.index_node(&mut vec![root.name.clone()], &root);
            dataset.root = Some(root);
        } else {
            dataset
                .warnings
                .push("the datasets packet has no <data> element".to_string());
        }
        for lov_file in datasets.children_named("LOVFile") {
            for lov in lov_file.children_named("LOV") {
                for list in lov.elements() {
                    let list_name = list.name.clone();
                    let mut entries = Vec::new();
                    for entry in list.elements() {
                        collect_lov_entries(entry, &mut entries);
                    }
                    if entries.is_empty() {
                        continue;
                    }
                    dataset.lov_table_count += 1;
                    dataset.lov_entries += entries.len();
                    // `CountryList` and `Country` both find the list: bindItems references use
                    // one or the other depending on the producer. CityList groups its entries by
                    // province, so the first leaf name (`City`) is the useful alias.
                    let singular = first_leaf_name(list).unwrap_or_else(|| list_name.clone());
                    dataset
                        .lov
                        .entry(list_name)
                        .or_insert_with(|| entries.clone());
                    dataset
                        .lov
                        .entry(singular)
                        .or_insert_with(|| entries.clone());
                }
            }
        }
        Ok(dataset)
    }

    fn index_node(&mut self, path: &mut Vec<String>, node: &DataNode) {
        let full = path.join("/");
        if !node.text.is_empty() {
            self.values.push((full.clone(), node.text.clone()));
            self.by_path.insert(full, node.text.clone());
            self.by_leaf
                .entry(node.name.clone())
                .or_default()
                .push(node.text.clone());
        }
        let mut seen: BTreeMap<&str, usize> = BTreeMap::new();
        for child in &node.children {
            let index = seen.entry(child.name.as_str()).or_insert(0);
            let name = format!("{}[{}]", child.name, index);
            *index += 1;
            path.push(name);
            self.index_node(path, child);
            path.pop();
        }
    }

    /// Exact path lookup. Path components include occurrence indices (`Country[0]`).
    pub fn value_at(&self, path: &[String]) -> Option<&str> {
        self.by_path.get(&path.join("/")).map(String::as_str)
    }

    /// A unique leaf value, used when a producer's data tree does not mirror the template
    /// paths exactly (LiveCycle sometimes omits intermediate `Row` groups).
    pub fn unique_leaf(&self, name: &str) -> Option<&str> {
        match self.by_leaf.get(name).map(Vec::as_slice) {
            Some([only]) => Some(only.as_str()),
            _ => None,
        }
    }

    /// Resolves a code through a `bindItems` reference such as
    /// `xfa.datasets.LOVFile.LOV.CountryOfIssueList.CountryOfIssue[*]`.
    pub fn lov_label(&self, reference: &str, value: &str) -> Option<String> {
        if value.is_empty() {
            return None;
        }
        let cleaned = reference.trim_end_matches("[*]").trim();
        let parts: Vec<&str> = cleaned.split('.').collect();
        let candidates: Vec<&str> = parts.iter().rev().take(2).copied().collect();
        for name in candidates {
            if let Some(entries) = self.lov.get(name)
                && let Some(entry) = entries
                    .iter()
                    .find(|entry| entry.value == value || entry.label == value)
            {
                return Some(entry.label.clone());
            }
        }
        None
    }

    /// Resolves the value a field should show, from the dataset and the template fallbacks.
    ///
    /// `path` is the field's template path in the data vocabulary (`form1/Page1/…/Name[0]`).
    /// The function is deliberately total: a field with no dataset value still renders its
    /// default items, and a code with no LOV entry is shown verbatim rather than dropped.
    pub fn resolve(
        &self,
        path: &[String],
        field: &FieldInfo,
        parent_path: Option<&[String]>,
    ) -> Option<String> {
        let mut raw = self.raw_value(path, parent_path, field);
        let mut value = raw.clone().unwrap_or_default();

        // Items map the saved value (usually a code) to the visible label.
        if !field.items.is_empty() {
            if let Some(index) = field
                .item_values
                .iter()
                .position(|candidate| candidate == &value)
            {
                if let Some(label) = field.items.get(index) {
                    value = label.clone();
                }
            } else if !field.item_values.is_empty()
                && field.item_values.iter().all(|item| item == &field.items[0])
            {
                // A single list is both labels and values.
            }
        }

        // LOV tables are referenced by bindItems; the code is not the label.
        if let Some(reference) = &field.bind_items
            && let Some(label) = self.lov_label(reference, &value)
        {
            value = label;
        }

        if value.is_empty()
            && let Some(default) = &field.default_value
        {
            value = default.clone();
            if !field.items.is_empty()
                && let Some(index) = field
                    .item_values
                    .iter()
                    .position(|candidate| candidate == default)
                && let Some(label) = field.items.get(index)
            {
                value = label.clone();
            }
            if let Some(reference) = &field.bind_items
                && let Some(label) = self.lov_label(reference, &value)
            {
                value = label;
            }
        }

        if value.is_empty() {
            raw = None;
        }
        if field.kind == FieldType::CheckButton {
            return raw.or(Some(value));
        }
        (!value.is_empty()).then_some(value)
    }

    fn raw_value(
        &self,
        path: &[String],
        parent_path: Option<&[String]>,
        field: &FieldInfo,
    ) -> Option<String> {
        if let Some(value) = self.value_at(path) {
            return Some(value.to_string());
        }
        if let Some(parent) = parent_path
            && let Some(value) = self.value_at(parent)
            && !field.item_values.is_empty()
        {
            return Some(value.to_string());
        }
        self.unique_leaf(&field_name(path)).map(str::to_string)
    }
}

/// Flattens one LOV entry. Some producers group entries one level deep (`CityList/AB/City`);
/// the group label is a concatenation, not a value, so recurse instead of taking its text.
fn collect_lov_entries(element: &Element, entries: &mut Vec<LovEntry>) {
    let children: Vec<&Element> = element.elements().collect();
    if !children.is_empty() {
        for child in children {
            collect_lov_entries(child, entries);
        }
        return;
    }
    let label = normalise_space(&element.text()).trim().to_string();
    let value = element
        .attribute("lic")
        .map(str::to_string)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| label.clone());
    if label.is_empty() && value.is_empty() {
        return;
    }
    entries.push(LovEntry { label, value });
}

fn first_leaf_name(element: &Element) -> Option<String> {
    for child in element.elements() {
        if child.elements().next().is_none() {
            return Some(child.name.clone());
        }
        if let Some(name) = first_leaf_name(child) {
            return Some(name);
        }
    }
    None
}

fn field_name(path: &[String]) -> String {
    path.last()
        .map(|component| {
            component
                .split_once('[')
                .map(|(name, _)| name)
                .unwrap_or(component)
                .to_string()
        })
        .unwrap_or_default()
}

/// A helper for the report: the value of a field rendered as a short string.
pub fn rich_to_text(rich: &[RichParagraph]) -> String {
    rich.iter()
        .map(|paragraph| paragraph.text())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Finds the datasets packet in a whole-XDP packet.
pub fn parse_from_xdp(bytes: &[u8]) -> Result<DataSet> {
    let text = String::from_utf8_lossy(bytes);
    let document = parse_xml(&text)
        .ok_or_else(|| XfaError::Malformed("the XDP packet is not XML".to_string()))?;
    let datasets = document
        .find("datasets")
        .ok_or_else(|| XfaError::Malformed("the XDP has no datasets packet".to_string()))?;
    if datasets.name.eq_ignore_ascii_case("datasets") {
        // Reuse the same parser by wrapping the element; it is already a packet-shaped tree.
        let xml = format!("<datasets>{}</datasets>", element_inner(datasets));
        return DataSet::parse(xml.as_bytes());
    }
    Err(XfaError::Malformed(
        "the XDP has no datasets packet".to_string(),
    ))
}

fn element_inner(element: &Element) -> String {
    // Only used for the whole-XDP fallback; keep the text and child names that matter.
    let mut out = String::new();
    for child in &element.children {
        match child {
            crate::xml::Node::Text(text) => out.push_str(text),
            crate::xml::Node::Element(child) => {
                out.push('<');
                out.push_str(&child.name);
                for (key, value) in &child.attributes {
                    out.push_str(&format!(" {key}=\"{}\"", value.replace('"', "&quot;")));
                }
                out.push('>');
                out.push_str(&element_inner(child));
                out.push_str("</");
                out.push_str(&child.name);
                out.push('>');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::FieldInfo;

    const DATASETS: &str = r#"
      <xfa:datasets xmlns:xfa="http://www.xfa.org/schema/xfa-data/1.0/">
        <LOVFile><LOV>
          <CountryList>
            <Country lic="252">Afghanistan</Country>
            <Country lic="511">Canada</Country>
          </CountryList>
        </LOV></LOVFile>
        <xfa:data><form1><Page1><Country>511</Country><Name>Ada</Name></Page1></form1></xfa:data>
      </xfa:datasets>
    "#;

    #[test]
    fn indexes_values_and_lov() {
        let dataset = DataSet::parse(DATASETS.as_bytes()).expect("dataset");
        assert_eq!(
            dataset.value_at(&[
                "form1".to_string(),
                "Page1[0]".to_string(),
                "Country[0]".to_string()
            ]),
            Some("511")
        );
        assert_eq!(
            dataset
                .lov_label("xfa.datasets.LOVFile.LOV.CountryList.Country[*]", "511")
                .as_deref(),
            Some("Canada")
        );
        assert_eq!(dataset.values.len(), 2);
        assert_eq!(dataset.lov_entries, 2);
        assert_eq!(dataset.lov_table_count, 1);
    }

    #[test]
    fn resolves_items_then_lov_then_default() {
        let dataset = DataSet::parse(DATASETS.as_bytes()).expect("dataset");
        let field = FieldInfo {
            items: vec!["Canada".to_string()],
            item_values: vec!["511".to_string()],
            ..FieldInfo::default()
        };
        let path = vec![
            "form1".to_string(),
            "Page1[0]".to_string(),
            "Country[0]".to_string(),
        ];
        assert_eq!(
            dataset.resolve(&path, &field, None).as_deref(),
            Some("Canada")
        );
        let field = FieldInfo {
            bind_items: Some("xfa.datasets.LOVFile.LOV.CountryList.Country[*]".to_string()),
            ..FieldInfo::default()
        };
        assert_eq!(
            dataset.resolve(&path, &field, None).as_deref(),
            Some("Canada")
        );
    }

    #[test]
    fn report_values_include_paths() {
        let dataset = DataSet::parse(DATASETS.as_bytes()).expect("dataset");
        assert!(
            dataset
                .values
                .iter()
                .any(|(path, value)| path.ends_with("Page1[0]/Name[0]") && value == "Ada")
        );
    }
}
