//! Simple XML tree parser for GlobalProtect protocol responses.

use std::str;

use quick_xml::events::Event;
use quick_xml::Reader;

use crate::error::ProtoError;

/// A lightweight XML tree node for convenient traversal.
#[derive(Debug, Clone, Default)]
pub struct XmlNode {
    pub name: String,
    pub attributes: Vec<(String, String)>,
    pub text: String,
    pub children: Vec<XmlNode>,
}

impl XmlNode {
    /// Parse an XML string into a tree rooted at the document element.
    pub fn parse(xml: &str) -> Result<Self, ProtoError> {
        if xml.len() > 2 * 1024 * 1024 {
            return Err(ProtoError::XmlParse("XML response too large".into()));
        }
        let mut reader = Reader::from_str(xml);
        reader.config_mut().check_end_names = true;
        let mut stack = vec![XmlNode::default()];
        let mut nodes = 0usize;
        loop {
            match reader.read_event() {
                Ok(Event::Start(ref e)) => {
                    nodes += 1;
                    if stack.len() >= 64 || nodes > 32768 {
                        return Err(ProtoError::XmlParse("XML structure limit exceeded".into()));
                    }
                    stack.push(Self::from_start(e)?);
                }
                Ok(Event::End(_)) => {
                    if stack.len() <= 1 {
                        return Err(ProtoError::XmlParse("unexpected XML end".into()));
                    }
                    let mut node = stack
                        .pop()
                        .ok_or_else(|| ProtoError::XmlParse("missing XML node".into()))?;
                    node.text = node.text.trim().to_owned();
                    if let Some(parent) = stack.last_mut() {
                        parent.children.push(node);
                    }
                }
                Ok(Event::Empty(ref e)) => {
                    nodes += 1;
                    if nodes > 32768 {
                        return Err(ProtoError::XmlParse("XML structure limit exceeded".into()));
                    }
                    if let Some(parent) = stack.last_mut() {
                        parent.children.push(Self::from_start(e)?);
                    }
                }
                Ok(Event::Text(ref e)) => {
                    let text = e
                        .xml_content(quick_xml::XmlVersion::Implicit1_0)
                        .map_err(|e| ProtoError::XmlParse(e.to_string()))?;
                    if let Some(current) = stack.last_mut() {
                        current.text.push_str(&text);
                    }
                }
                Ok(Event::CData(ref e)) => {
                    let text = e
                        .decode()
                        .map_err(|e| ProtoError::XmlParse(e.to_string()))?;
                    if let Some(current) = stack.last_mut() {
                        current.text.push_str(&text);
                    }
                }
                Ok(Event::GeneralRef(ref e)) => {
                    let reference = e
                        .decode()
                        .map_err(|e| ProtoError::XmlParse(e.to_string()))?;
                    let encoded = format!("&{reference};");
                    let value = quick_xml::escape::unescape(&encoded)
                        .map_err(|e| ProtoError::XmlParse(e.to_string()))?;
                    if let Some(current) = stack.last_mut() {
                        current.text.push_str(&value);
                    }
                }
                Ok(Event::DocType(_)) => {
                    return Err(ProtoError::XmlParse(
                        "XML document types are unsupported".into(),
                    ))
                }
                Ok(Event::Eof) => break,
                Err(e) => return Err(ProtoError::XmlParse(e.to_string())),
                _ => {}
            }
        }
        if stack.len() != 1 {
            return Err(ProtoError::XmlParse("incomplete XML document".into()));
        }
        let mut root = stack
            .pop()
            .ok_or_else(|| ProtoError::XmlParse("empty XML document".into()))?;
        if root.children.len() != 1 || !root.text.trim().is_empty() {
            return Err(ProtoError::XmlParse("invalid XML document root".into()));
        }
        Ok(root.children.remove(0))
    }

    fn from_start(e: &quick_xml::events::BytesStart<'_>) -> Result<Self, ProtoError> {
        let name = str::from_utf8(e.name().as_ref())
            .map_err(|e| ProtoError::XmlParse(e.to_string()))?
            .to_owned();
        let mut attributes = Vec::new();
        for attribute in e.attributes() {
            let attribute = attribute.map_err(|e| ProtoError::XmlParse(e.to_string()))?;
            if attributes.len() >= 128 {
                return Err(ProtoError::XmlParse("too many XML attributes".into()));
            }
            let key = str::from_utf8(attribute.key.as_ref())
                .map_err(|e| ProtoError::XmlParse(e.to_string()))?
                .to_owned();
            let value = attribute
                .normalized_value(quick_xml::XmlVersion::Implicit1_0)
                .map_err(|e| ProtoError::XmlParse(e.to_string()))?
                .into_owned();
            attributes.push((key, value));
        }
        Ok(Self {
            name,
            attributes,
            text: String::new(),
            children: Vec::new(),
        })
    }

    /// Find a direct child element by tag name.
    pub fn child(&self, name: &str) -> Option<&XmlNode> {
        self.children.iter().find(|c| c.name == name)
    }

    /// Get the text content of a direct child element.
    pub fn child_text(&self, name: &str) -> Option<&str> {
        self.child(name)
            .map(|c| c.text.as_str())
            .filter(|s| !s.is_empty())
    }

    /// Get an attribute value.
    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attributes
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }

    /// Iterate over direct children with the given tag name.
    pub fn children_named<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a XmlNode> {
        self.children.iter().filter(move |c| c.name == name)
    }

    /// Navigate to a descendant by a slash-separated path (e.g. `"gateways/external/list"`).
    pub fn at(&self, path: &str) -> Option<&XmlNode> {
        let mut current = self;
        for part in path.split('/') {
            current = current.child(part)?;
        }
        Some(current)
    }

    /// Get the text content of a descendant at the given path.
    pub fn text_at(&self, path: &str) -> Option<&str> {
        self.at(path)
            .map(|n| n.text.as_str())
            .filter(|s| !s.is_empty())
    }

    /// Recursively find the first descendant with the given tag name (depth-first).
    pub fn find(&self, name: &str) -> Option<&XmlNode> {
        for child in &self.children {
            if child.name == name {
                return Some(child);
            }
            if let Some(found) = child.find(name) {
                return Some(found);
            }
        }
        None
    }

    /// Find the text content of the first descendant with the given tag name.
    pub fn find_text(&self, name: &str) -> Option<&str> {
        self.find(name)
            .map(|n| n.text.as_str())
            .filter(|s| !s.is_empty())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_simple() {
        let xml = r#"<root><child>hello</child><other attr="val"/></root>"#;
        let node = XmlNode::parse(xml).unwrap();
        assert_eq!(node.name, "root");
        assert_eq!(node.child_text("child"), Some("hello"));
        assert_eq!(node.child("other").unwrap().attr("attr"), Some("val"));
    }

    #[test]
    fn parse_nested_path() {
        let xml = r#"<a><b><c>deep</c></b></a>"#;
        let node = XmlNode::parse(xml).unwrap();
        assert_eq!(node.text_at("b/c"), Some("deep"));
    }
}
