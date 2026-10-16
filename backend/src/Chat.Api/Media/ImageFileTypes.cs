namespace Chat.Api.Media;

internal static class ImageFileTypes
{
    public static string? Detect(ReadOnlySpan<byte> header)
    {
        if (header.StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })) return "image/png";
        if (header.StartsWith(new byte[] { 255, 216, 255 })) return "image/jpeg";
        if (header.StartsWith("GIF87a"u8) || header.StartsWith("GIF89a"u8)) return "image/gif";
        if (header.Length >= 12 && header[..4].SequenceEqual("RIFF"u8) &&
            header.Slice(8, 4).SequenceEqual("WEBP"u8)) return "image/webp";
        if (header.StartsWith("BM"u8)) return "image/bmp";
        if (header.Length >= 12 && header.Slice(4, 4).SequenceEqual("ftyp"u8))
        {
            var brand = System.Text.Encoding.ASCII.GetString(header.Slice(8, 4));
            if (brand is "heic" or "heix" or "hevc" or "hevx" or "mif1") return "image/heic";
            if (brand is "avif" or "avis") return "image/avif";
        }
        return null;
    }
}
