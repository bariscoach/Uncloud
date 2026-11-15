//! An `.xmp` sidecar for each exported file: dates, favorite rating, and GPS location.
//! Readable by Lightroom and most other photo apps.

use crate::library::Asset;
use chrono::SecondsFormat;

pub fn sidecar(asset: &Asset) -> String {
    let mut attributes: Vec<(&str, String)> = Vec::new();
    if let Some(created) = asset.created {
        let value = created.to_rfc3339_opts(SecondsFormat::Secs, true);
        attributes.push(("xmp:CreateDate", value.clone()));
        attributes.push(("photoshop:DateCreated", value));
    }
    if let Some(modified) = asset.modified {
        attributes.push((
            "xmp:ModifyDate",
            modified.to_rfc3339_opts(SecondsFormat::Secs, true),
        ));
    }
    if asset.favorite {
        attributes.push(("xmp:Rating", "5".to_owned()));
    }
    if let (Some(latitude), Some(longitude)) = (asset.latitude, asset.longitude) {
        attributes.push(("exif:GPSLatitude", gps(latitude, 'N', 'S')));
        attributes.push(("exif:GPSLongitude", gps(longitude, 'E', 'W')));
    }

    let mut xml = String::new();
    xml.push_str("<?xpacket begin=\"\u{feff}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n");
    xml.push_str("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n");
    xml.push_str("  <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n");
    xml.push_str("    <rdf:Description rdf:about=\"\"\n");
    xml.push_str("        xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"\n");
    xml.push_str("        xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\"\n");
    xml.push_str("        xmlns:exif=\"http://ns.adobe.com/exif/1.0/\"");
    for (name, value) in &attributes {
        xml.push_str(&format!("\n        {name}=\"{}\"", escape(value)));
    }
    xml.push_str("/>\n  </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end=\"w\"?>\n");
    xml
}

/// Exif GPS format: degrees, then decimal minutes, then a hemisphere letter, e.g. `41,53.4000N`.
fn gps(value: f64, positive: char, negative: char) -> String {
    let hemisphere = if value < 0.0 { negative } else { positive };
    let absolute = value.abs();
    let degrees = absolute.floor();
    let minutes = (absolute - degrees) * 60.0;
    format!("{},{minutes:.4}{hemisphere}", degrees as u32)
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}
