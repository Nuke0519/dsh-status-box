using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using DSHStatusBox.Core;

namespace DSHStatusBox.App;

internal enum StatusVisual
{
    Offline,
    Idle,
    Running,
    Waiting,
    Done,
}

/// <summary>
/// Renders the DeepSeek whale silhouette into tray icons: the glyph and the count
/// badge share the state colour, mirroring the macOS menu-bar item (orange = you
/// have something to handle, green = running, blue = finished unread, grey = not
/// connected).
/// </summary>
internal sealed class WhaleIcons : IDisposable
{
    private const int CanvasSize = 32;
    private readonly byte[] _maskAlpha;
    private readonly int _maskWidth;
    private readonly int _maskHeight;
    private readonly Dictionary<(StatusVisual, int), Icon> _cache = new();
    private bool _disposed;

    public WhaleIcons()
    {
        using Stream? stream = typeof(WhaleIcons).Assembly
            .GetManifestResourceStream("DSHStatusBox.App.whale.png");
        if (stream == null)
        {
            throw new InvalidOperationException("embedded whale.png is missing");
        }

        using var source = new Bitmap(stream);
        _maskWidth = source.Width;
        _maskHeight = source.Height;
        _maskAlpha = new byte[_maskWidth * _maskHeight];
        for (int y = 0; y < _maskHeight; y++)
        {
            for (int x = 0; x < _maskWidth; x++)
            {
                _maskAlpha[y * _maskWidth + x] = source.GetPixel(x, y).A;
            }
        }
    }

    public Icon Get(StatusVisual visual, int count)
    {
        count = Math.Clamp(count, 0, 99);
        if (_cache.TryGetValue((visual, count), out Icon? cached))
        {
            return cached;
        }

        using Bitmap bitmap = Render(visual, count);
        IntPtr handle = bitmap.GetHicon();
        Icon icon = (Icon)Icon.FromHandle(handle).Clone();
        DestroyIcon(handle);
        _cache[(visual, count)] = icon;
        return icon;
    }

    private Bitmap Render(StatusVisual visual, int count)
    {
        Color color = ColorFor(visual);
        var bitmap = new Bitmap(CanvasSize, CanvasSize);
        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            graphics.Clear(Color.Transparent);

            // whale keeps its 1.357 aspect ratio inside the 32px box
            const float glyphWidth = 28f;
            float glyphHeight = glyphWidth * _maskHeight / _maskWidth;
            float left = (CanvasSize - glyphWidth) / 2f;
            float top = (CanvasSize - glyphHeight) / 2f - 1f;

            for (int y = 0; y < CanvasSize; y++)
            {
                for (int x = 0; x < CanvasSize; x++)
                {
                    float u = (x - left) / glyphWidth;
                    float v = (y - top) / glyphHeight;
                    if (u < 0 || u >= 1 || v < 0 || v >= 1)
                    {
                        continue;
                    }

                    int mx = (int)(u * _maskWidth);
                    int my = (int)(v * _maskHeight);
                    byte alpha = _maskAlpha[my * _maskWidth + mx];
                    if (alpha < 24)
                    {
                        continue;
                    }

                    int blended = alpha * 245 / 255;
                    bitmap.SetPixel(x, y, Color.FromArgb(blended, color));
                }
            }

            if (count > 0)
            {
                DrawBadge(graphics, color, count);
            }
        }

        return bitmap;
    }

    private static void DrawBadge(Graphics graphics, Color color, int count)
    {
        string label = count > 9 ? "9+" : count.ToString();
        const float badgeSize = 17f;
        var badge = new RectangleF(CanvasSize - badgeSize - 0.5f, CanvasSize - badgeSize - 0.5f, badgeSize, badgeSize);
        using (var fill = new SolidBrush(color))
        {
            graphics.FillEllipse(fill, badge);
        }

        using var border = new Pen(Color.FromArgb(220, Color.White), 1.2f);
        graphics.DrawEllipse(border, badge);

        using var font = new Font("Segoe UI", count > 9 ? 8f : 9.5f, FontStyle.Bold, GraphicsUnit.Pixel);
        using var text = new SolidBrush(Color.White);
        using var format = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center,
        };
        graphics.DrawString(label, font, text, new RectangleF(badge.X, badge.Y + 0.5f, badge.Width, badge.Height), format);
    }

    private static Color ColorFor(StatusVisual visual) => visual switch
    {
        StatusVisual.Waiting => Color.FromArgb(0xE5, 0x8A, 0x2B),
        StatusVisual.Running => Color.FromArgb(0x2F, 0x9E, 0x63),
        StatusVisual.Done => Color.FromArgb(0x2E, 0x7B, 0xE0),
        StatusVisual.Idle => Color.FromArgb(0x8A, 0x8F, 0x98),
        _ => Color.FromArgb(0x8A, 0x8F, 0x98),
    };

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        foreach (Icon icon in _cache.Values)
        {
            icon.Dispose();
        }

        _cache.Clear();
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);
}
