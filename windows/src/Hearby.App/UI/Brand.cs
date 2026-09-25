// Brand — Hearby's identity on Windows: the mark (closing double quote ”, drawn from geometry), the hearby” logotype and the
// "Powered by" wordmark (images, tinted with the ink). Trademark assets, not covered by the MIT license: the geometry below and
// the images in Assets/ follow Sources/HearbyUI/Resources/Brand/TRADEMARK.md (same terms as HearbyMarkShape.swift).
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace Hearby.App.UI;

public static class Brand
{
    /// Mark geometry (from hearby_mark_v1.svg, box 983.3 × 1000): one quote drawn twice, gap = width × 0.125
    public const double BoxWidth = 983.3, BoxHeight = 1000.0;
    const string PathData =
        "M 167.6,0.4 C 166.9,0.4 164.2,1.1 162.7,1.5 C 159.3,2.6 158.5,2.6 149.5,3 L 139.6,3.4 L 135.1,4.5 C 132.4,5.3 128.3,6.4 126,7.2 C 111.6,10.2 " +
        "100.6,14.8 88.9,22.3 C 86.3,24.2 80.6,27.6 76,29.9 C 60.2,37.8 54.1,42.8 38.6,58.6 C 28.8,69.2 19.7,88.5 14.4,110.5 C 14,112.8 12.9,116.5 12.1,118.4 C " +
        "9.1,126.7 7.6,132 7.2,137 C 6.8,141.9 6.4,144.2 3.8,151.7 L 3,154.7 L 2.6,225.1 L 2.6,295.5 L 1.1,300.4 L 0,305 L 0,317.1 L 0,328.8 L 1.1,333 L " +
        "2.3,336.7 L 2.6,401.1 C 3,458.9 3,465.8 3.4,468 C 3.8,469.5 4.9,472.6 5.7,475.2 L 6.8,480.1 L 7.2,493.8 L 7.6,507.4 L 8.7,511.5 C 9.8,515.3 9.8,516.1 " +
        "10.2,523.6 C 10.6,532.7 10.2,531.6 13.2,541.1 C 14,542.9 14.8,546.3 15.5,549 C 15.9,551.6 17.4,556.9 18.9,561.1 C 20.1,565.3 21.6,570.6 22.3,572.8 C " +
        "23.8,580 24.6,581.2 32.5,592.9 C 42.8,608 56.4,617.9 74.2,623.5 C 85.9,627.7 93.5,629.2 100.6,629.6 C 106.7,630 107.1,630 116.5,633 C 119.6,633.7 " +
        "120.3,633.7 131.3,634.1 C 142.3,634.5 142.6,634.5 146.4,635.6 C 150.2,636.8 151,636.8 158.5,637.2 C 167.2,637.5 168.7,637.9 174.4,639.8 C 175.9,640.6 " +
        "179.3,641.3 182,642.1 C 192.2,644.7 202.8,650.4 208.5,656.5 C 214.2,662.1 215.3,664.4 219.1,675.4 L 222.1,683.3 L 222.1,699.6 L 222.1,715.9 L " +
        "220.2,721.9 C 219.1,725.3 217.9,729.1 217.6,730.6 C 216.8,735.5 214.2,742.3 211.9,746.1 C 211.1,747.3 208.9,751.8 206.6,756.3 C 196.7,774.9 " +
        "186.2,788.1 175.6,794.9 C 173.3,796.4 169.5,798.7 166.9,800.6 C 160,805.5 144.9,813.1 136.2,816.1 C 123.3,820.7 105.6,825.2 98.8,826.3 C 96.1,826.7 " +
        "88.9,828.6 82.5,830.5 C 78.7,831.6 76.8,832.8 70.4,836.9 C 59,844.5 53.7,851.7 51.5,861.9 C 51.1,864.2 49.9,868 49.6,870.2 L 48.4,874.4 L 48.4,886.1 L " +
        "48.4,897.8 L 49.6,902 L 50.7,905.8 L 51.1,928.5 C 51.1,944.8 51.5,951.9 51.8,952.7 C 57.1,969.7 59,973.9 66.2,981.1 C 72.6,987.5 83.2,994.3 91.6,996.6 " +
        "C 93.1,997 96.1,998.1 99.1,998.9 L 104,1000 L 148.7,1000 L 193.7,1000 L 197.9,998.9 C 202,997.7 202.8,997.7 210.4,997.4 C 217.6,997 218.3,997 " +
        "221.7,995.8 C 227.8,993.9 229.7,993.6 235.3,992.8 C 239.9,992.1 242.1,991.7 248.2,989.8 C 252.4,988.3 257.7,986.8 259.9,986 C 263,984.9 268.3,982.6 " +
        "276.2,978.8 C 282.6,975.4 289.4,972.4 291.7,971.6 C 297.4,969.7 308.4,964.4 314.4,960.3 C 317.1,958.4 321.2,956.1 323.5,955 C 329.2,952.3 330.7,950.8 " +
        "335.6,946.7 C 337.9,944.8 341.3,941.7 343.5,940.2 C 349.6,936.4 385.5,900.1 389.3,894.8 C 390.5,892.9 392.4,890.3 393.5,888.8 C 394.6,887.2 " +
        "397.7,882.3 400.7,877.8 C 403.7,873.3 406.7,868.3 407.5,867.2 C 409.4,864.2 410.5,861.9 412.4,857.4 C 413.2,855.5 416.2,848.3 419.6,841.8 C " +
        "425.3,830.1 425.3,829.7 426.4,824.8 C 427.2,821.8 427.9,818 429.1,816.5 C 432.1,809.7 433.2,805.9 434,802.1 C 434.4,799.8 435.5,796.4 436.2,794.6 C " +
        "437,792.7 437.8,788.9 438.5,786.2 C 438.9,783.6 439.7,780.2 440,778.7 C 440.4,777.1 441.2,774.1 441.5,771.9 C 441.9,770 442.7,766.9 443.4,765.4 C " +
        "445.3,759.4 445.7,756.3 446.1,749.9 C 446.5,745.7 446.8,742.3 447.6,738.6 C 448.4,735.1 448.7,731 449.1,728 C 449.5,724.2 449.9,721.2 450.6,718.1 C " +
        "451.8,714 451.8,712.4 452.1,705.6 C 452.5,699.2 452.5,697.7 453.7,693.9 L 454.8,689.4 L 455.2,674.2 C 455.5,657.2 455.2,659.9 458.6,648.9 L " +
        "459.3,645.5 L 459.7,611.4 L 460.1,577.4 L 461.2,572.8 L 462.7,567.9 L 462.7,379.9 L 462.7,191.4 L 461.2,187.7 L 460.1,183.5 L 459.7,166.5 L " +
        "459.3,149.1 L 457.8,144.5 C 455.5,138.1 455.5,137.7 455.2,130.9 C 454.8,126.4 454.4,124.1 454,121.8 C 453.3,119.9 452.5,116.5 452.1,114.3 C " +
        "451.4,110.9 450.6,107.5 448.4,101.8 C 446.8,97.6 445.3,92.3 444.6,89.7 C 443.4,85.1 435.1,68.1 431.7,63.2 C 429.1,58.6 407.1,37.5 402.6,34.4 C " +
        "400.7,32.9 396.5,30.6 393.9,28.8 C 387.1,23.8 374.6,17.4 366.6,14.8 C 363.2,13.6 357.2,11.7 353.8,10.6 C 349.2,9.1 345.1,7.9 342.4,7.6 C 339.8,7.2 " +
        "336.4,6.4 334.8,5.7 C 328.4,3.4 328.4,3.4 314,3 L 300.4,2.6 L 296.3,1.5 L 292.5,0.4 L 230.8,0 C 197.1,0 168.4,0.4 167.6,0.4 Z M 688.1,0.4 C 687.4,0.4 " +
        "684.7,1.1 683.2,1.5 C 679.8,2.6 679,2.6 670,3 L 660.1,3.4 L 655.6,4.5 C 652.9,5.3 648.8,6.4 646.5,7.2 C 632.1,10.2 621.1,14.8 609.4,22.3 C 606.8,24.2 " +
        "601.1,27.6 596.5,29.9 C 580.7,37.8 574.6,42.8 559.1,58.6 C 549.3,69.2 540.2,88.5 534.9,110.5 C 534.5,112.8 533.4,116.5 532.6,118.4 C 529.6,126.7 " +
        "528.1,132 527.7,137 C 527.3,141.9 526.9,144.2 524.3,151.7 L 523.5,154.7 L 523.1,225.1 L 523.1,295.5 L 521.6,300.4 L 520.5,305 L 520.5,317.1 L " +
        "520.5,328.8 L 521.6,333 L 522.8,336.7 L 523.1,401.1 C 523.5,458.9 523.5,465.8 523.9,468 C 524.3,469.5 525.4,472.6 526.2,475.2 L 527.3,480.1 L " +
        "527.7,493.8 L 528.1,507.4 L 529.2,511.5 C 530.3,515.3 530.3,516.1 530.7,523.6 C 531.1,532.7 530.7,531.6 533.7,541.1 C 534.5,542.9 535.3,546.3 536,549 " +
        "C 536.4,551.6 537.9,556.9 539.4,561.1 C 540.6,565.3 542.1,570.6 542.8,572.8 C 544.3,580 545.1,581.2 553,592.9 C 563.3,608 576.9,617.9 594.7,623.5 C " +
        "606.4,627.7 614,629.2 621.1,629.6 C 627.2,630 627.6,630 637,633 C 640.1,633.7 640.8,633.7 651.8,634.1 C 662.8,634.5 663.1,634.5 666.9,635.6 C " +
        "670.7,636.8 671.5,636.8 679,637.2 C 687.7,637.5 689.2,637.9 694.9,639.8 C 696.4,640.6 699.8,641.3 702.5,642.1 C 712.7,644.7 723.3,650.4 729,656.5 C " +
        "734.7,662.1 735.8,664.4 739.6,675.4 L 742.6,683.3 L 742.6,699.6 L 742.6,715.9 L 740.7,721.9 C 739.6,725.3 738.4,729.1 738.1,730.6 C 737.3,735.5 " +
        "734.7,742.3 732.4,746.1 C 731.6,747.3 729.4,751.8 727.1,756.3 C 717.2,774.9 706.7,788.1 696.1,794.9 C 693.8,796.4 690,798.7 687.4,800.6 C 680.5,805.5 " +
        "665.4,813.1 656.7,816.1 C 643.8,820.7 626.1,825.2 619.3,826.3 C 616.6,826.7 609.4,828.6 603,830.5 C 599.2,831.6 597.3,832.8 590.9,836.9 C 579.5,844.5 " +
        "574.2,851.7 572,861.9 C 571.6,864.2 570.4,868 570.1,870.2 L 568.9,874.4 L 568.9,886.1 L 568.9,897.8 L 570.1,902 L 571.2,905.8 L 571.6,928.5 C " +
        "571.6,944.8 572,951.9 572.3,952.7 C 577.6,969.7 579.5,973.9 586.7,981.1 C 593.1,987.5 603.7,994.3 612.1,996.6 C 613.6,997 616.6,998.1 619.6,998.9 L " +
        "624.5,1000 L 669.2,1000 L 714.2,1000 L 718.4,998.9 C 722.5,997.7 723.3,997.7 730.9,997.4 C 738.1,997 738.8,997 742.2,995.8 C 748.3,993.9 750.2,993.6 " +
        "755.8,992.8 C 760.4,992.1 762.6,991.7 768.7,989.8 C 772.9,988.3 778.2,986.8 780.4,986 C 783.5,984.9 788.8,982.6 796.7,978.8 C 803.1,975.4 809.9,972.4 " +
        "812.2,971.6 C 817.9,969.7 828.9,964.4 834.9,960.3 C 837.6,958.4 841.7,956.1 844,955 C 849.7,952.3 851.2,950.8 856.1,946.7 C 858.4,944.8 861.8,941.7 " +
        "864,940.2 C 870.1,936.4 906,900.1 909.8,894.8 C 911,892.9 912.9,890.3 914,888.8 C 915.1,887.2 918.2,882.3 921.2,877.8 C 924.2,873.3 927.2,868.3 " +
        "928,867.2 C 929.9,864.2 931,861.9 932.9,857.4 C 933.7,855.5 936.7,848.3 940.1,841.8 C 945.8,830.1 945.8,829.7 946.9,824.8 C 947.7,821.8 948.4,818 " +
        "949.6,816.5 C 952.6,809.7 953.7,805.9 954.5,802.1 C 954.9,799.8 956,796.4 956.7,794.6 C 957.5,792.7 958.3,788.9 959,786.2 C 959.4,783.6 960.2,780.2 " +
        "960.5,778.7 C 960.9,777.1 961.7,774.1 962,771.9 C 962.4,770 963.2,766.9 963.9,765.4 C 965.8,759.4 966.2,756.3 966.6,749.9 C 967,745.7 967.3,742.3 " +
        "968.1,738.6 C 968.9,735.1 969.2,731 969.6,728 C 970,724.2 970.4,721.2 971.1,718.1 C 972.3,714 972.3,712.4 972.6,705.6 C 973,699.2 973,697.7 " +
        "974.2,693.9 L 975.3,689.4 L 975.7,674.2 C 976,657.2 975.7,659.9 979.1,648.9 L 979.8,645.5 L 980.2,611.4 L 980.6,577.4 L 981.7,572.8 L 983.2,567.9 L " +
        "983.2,379.9 L 983.2,191.4 L 981.7,187.7 L 980.6,183.5 L 980.2,166.5 L 979.8,149.1 L 978.3,144.5 C 976,138.1 976,137.7 975.7,130.9 C 975.3,126.4 " +
        "974.9,124.1 974.5,121.8 C 973.8,119.9 973,116.5 972.6,114.3 C 971.9,110.9 971.1,107.5 968.9,101.8 C 967.3,97.6 965.8,92.3 965.1,89.7 C 963.9,85.1 " +
        "955.6,68.1 952.2,63.2 C 949.6,58.6 927.6,37.5 923.1,34.4 C 921.2,32.9 917,30.6 914.4,28.8 C 907.6,23.8 895.1,17.4 887.1,14.8 C 883.7,13.6 877.7,11.7 " +
        "874.3,10.6 C 869.7,9.1 865.6,7.9 862.9,7.6 C 860.3,7.2 856.9,6.4 855.3,5.7 C 848.9,3.4 848.9,3.4 834.5,3 L 820.9,2.6 L 816.8,1.5 L 813,0.4 L 751.3,0 C " +
        "717.6,0 688.9,0.4 688.1,0.4 Z ";

    static Geometry? geometry;
    public static Geometry Geometry
    {
        get
        {
            if (geometry != null) return geometry;
            var g = System.Windows.Media.Geometry.Parse("F1 " + PathData);
            g.Freeze();
            return geometry = g;
        }
    }

    static BitmapImage? Load(string name)
    {
        try
        {
            var b = new BitmapImage();
            b.BeginInit();
            b.UriSource = new Uri($"pack://application:,,,/Hearby;component/Assets/{name}", UriKind.Absolute);
            b.CacheOption = BitmapCacheOption.OnLoad;
            b.EndInit();
            b.Freeze();
            return b;
        }
        catch { return null; }
    }
    public static readonly Lazy<BitmapImage?> Logotype = new(() => Load("hearby_logotype.png"));
    public static readonly Lazy<BitmapImage?> LogotypeWord = new(() => Load("hearby_logotype_word.png"));
    public static readonly Lazy<BitmapImage?> Wordmark = new(() => Load("intention_wordmark.png"));
    public static readonly Lazy<BitmapImage?> WizardHero = new(() => Load("hearby_wizard_hero.jpg"));
    public static readonly Lazy<BitmapImage?> AppIcon = new(() => Load("hearby_icon_256.png"));

    /// A template image (black on transparent) painted in the given brush
    public static FrameworkElement Tinted(BitmapImage? img, double height, Brush ink, string fallback)
    {
        if (img == null) return new TextBlock { Text = fallback, FontSize = height * 1.2, FontWeight = FontWeights.Black, Foreground = ink };
        return new Rectangle
        {
            Height = height,
            Width = height * img.PixelWidth / img.PixelHeight,
            Fill = ink,
            OpacityMask = new ImageBrush(img) { Stretch = Stretch.Uniform },
            SnapsToDevicePixels = true,
        };
    }

    public static FrameworkElement LogotypeView(double height, Brush? ink = null, bool wordOnly = false)
    {
        var e = Tinted(wordOnly ? LogotypeWord.Value : Logotype.Value, height, ink ?? Theme.InkSoft, "hearby”");
        System.Windows.Automation.AutomationProperties.SetName(e, "Hearby");
        return e;
    }

    /// "Powered by" + the maker's wordmark (left), hearby” (right)
    public static FrameworkElement PoweredBy(bool showWordmark = true)
    {
        var row = new DockPanel { LastChildFill = false };
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(Neu.Text("Powered by", Neu.TMicro, Theme.InkSoft, wrap: false));
        if (Wordmark.Value != null)
        {
            var wm = Tinted(Wordmark.Value, 8.5, Theme.InkSoft, "");
            wm.Margin = new Thickness(Neu.SM, 1, 0, 0);
            wm.VerticalAlignment = VerticalAlignment.Center;
            left.Children.Add(wm);
        }
        DockPanel.SetDock(left, Dock.Left);
        row.Children.Add(left);
        if (showWordmark)
        {
            var lt = LogotypeView(12);
            DockPanel.SetDock(lt, Dock.Right);
            row.Children.Add(lt);
        }
        return row;
    }
}

/// The mark as a "light point": idle / listening (breathing glow) / working / flash. At most one per screen.
public sealed class MarkView : Grid
{
    public enum Mode { Idle, Listening, Working, Flash }

    public MarkView(Mode mode = Mode.Idle, double size = 16, Brush? color = null)
    {
        var ink = color ?? Theme.InkStrong;
        double w = size * Brand.BoxWidth / Brand.BoxHeight;
        Width = size * 2.4; Height = size * 2.4;
        IsHitTestVisible = false;
        System.Windows.Automation.AutomationProperties.SetName(this, "Hearby");
        System.Windows.Shapes.Path Shape() => new()
        {
            Data = Brand.Geometry, Fill = ink, Stretch = Stretch.Uniform, Width = w, Height = size,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            RenderTransformOrigin = new Point(0.5, 0.5),
        };
        bool calm = !SystemParameters.ClientAreaAnimation;
        if (mode is Mode.Listening or Mode.Working)
        {
            var glow = Shape();
            glow.Effect = new BlurEffect { Radius = size * 0.9 };
            glow.Opacity = 0.3;
            Children.Add(glow);
            if (!calm)
            {
                var a = new DoubleAnimation(0.3, 0.8, TimeSpan.FromSeconds(1.6)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() };
                glow.BeginAnimation(OpacityProperty, a);
            }
        }
        if (mode == Mode.Flash && !calm)
        {
            var ring = new Ellipse { Stroke = ink, StrokeThickness = 1.2, Width = size * 1.2, Height = size * 1.2, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, RenderTransformOrigin = new Point(0.5, 0.5) };
            var st = new ScaleTransform(1, 1);
            ring.RenderTransform = st;
            Children.Add(ring);
            var grow = new DoubleAnimation(1, 2.3 / 1.2, TimeSpan.FromSeconds(0.55)) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } };
            st.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
            st.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
            ring.BeginAnimation(OpacityProperty, new DoubleAnimation(0.9, 0, TimeSpan.FromSeconds(0.55)));
        }
        var main = Shape();
        if (mode == Mode.Listening && !calm)
        {
            var st = new ScaleTransform(1, 1);
            main.RenderTransform = st;
            var a = new DoubleAnimation(1, 1.06, TimeSpan.FromSeconds(1.6)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() };
            st.BeginAnimation(ScaleTransform.ScaleXProperty, a);
            st.BeginAnimation(ScaleTransform.ScaleYProperty, a);
        }
        Children.Add(main);
    }
}
