import AppKit

/// Shared rich-text mutations: retain every attribute outside the requested field.
enum MacPDFTextFormatting {
    static func attributed(_ object: MacPDFObject) -> NSAttributedString {
        if let data = object.textRTF, let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { return text }
        let style = object.style
        var font = NSFont(name: style.fontName, size: style.fontSize) ?? .systemFont(ofSize: style.fontSize)
        if style.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = NSTextAlignment(rawValue: style.alignment) ?? .left
        return NSAttributedString(string: object.text, attributes: [.font: font, .foregroundColor: style.stroke.color, .paragraphStyle: paragraph, .underlineStyle: style.underline ? 1 : 0, .strikethroughStyle: style.strike ? 1 : 0])
    }
    static func apply(field: String, style: MacPDFStyle, to text: NSAttributedString, range: NSRange, scale: CGFloat = 1) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return result }
        switch field {
        case "fontName", "fontSize", "bold", "italic":
            text.enumerateAttribute(.font, in: range) { value, part, _ in
                let old = value as? NSFont ?? .systemFont(ofSize: style.fontSize * scale)
                var font = old
                if field == "fontName" { font = NSFont(name: style.fontName, size: old.pointSize) ?? old }
                if field == "fontSize" { font = NSFontManager.shared.convert(old, toSize: style.fontSize * scale) }
                if field == "bold" { font = style.bold ? NSFontManager.shared.convert(old, toHaveTrait: .boldFontMask) : NSFontManager.shared.convert(old, toNotHaveTrait: .boldFontMask) }
                if field == "italic" { font = style.italic ? NSFontManager.shared.convert(old, toHaveTrait: .italicFontMask) : NSFontManager.shared.convert(old, toNotHaveTrait: .italicFontMask) }
                result.addAttribute(.font, value: font, range: part)
            }
        case "stroke": result.addAttribute(.foregroundColor, value: style.stroke.color, range: range)
        case "underline": result.addAttribute(.underlineStyle, value: style.underline ? 1 : 0, range: range)
        case "strike": result.addAttribute(.strikethroughStyle, value: style.strike ? 1 : 0, range: range)
        case "alignment":
            text.enumerateAttribute(.paragraphStyle, in: range) { value, part, _ in
                let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                paragraph.alignment = NSTextAlignment(rawValue: style.alignment) ?? .left
                result.addAttribute(.paragraphStyle, value: paragraph, range: part)
            }
        default: break
        }
        return result
    }
}
