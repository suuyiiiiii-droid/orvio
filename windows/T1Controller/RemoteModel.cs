using System;
using System.Collections.Generic;
using System.IO.Compression;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Media3D;

namespace T1Controller;

internal sealed record RemoteFace(string Name, double Yaw, string[] Keys);
internal sealed record RemoteLabel(string Name, string Icon, string Action, string Guide, bool Left, double Level,
    bool Mappable, double[] Anchor);
internal sealed record RemoteLegend(string Text, bool Literal, string Secondary);
internal sealed record RemotePart(string Key, double[] Matrix, byte[] Vertices, byte[] Triangles, byte[]? Normals,
    byte[]? Uv, double[]? Color, RemoteLegend? Legend);
internal sealed record RemoteModel(string Name, RemotePart[] Parts, Dictionary<string, RemoteLabel> Keys, RemoteFace[] Faces)
{
    private static readonly Lazy<RemoteModel[]> Assets = new(() =>
    {
        var resource = Application.GetResourceStream(new Uri("RemoteModels.json.gz", UriKind.Relative))
            ?? throw new InvalidOperationException("找不到设备模型资源。");
        using var stream = resource.Stream;
        using var decoded = new GZipStream(stream, CompressionMode.Decompress);
        return JsonSerializer.Deserialize<RemoteModel[]>(decoded, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidOperationException("设备模型资源损坏。");
    });
    public static RemoteModel For(bool xiaomi) => Assets.Value[xiaomi ? 1 : 0];
}

internal static class RemoteMesh
{
    private static ReadOnlySpan<float> Floats(byte[] bytes) =>
        System.Runtime.InteropServices.MemoryMarshal.Cast<byte, float>(bytes);

    public static GeometryModel3D Create(RemotePart part)
    {
        var vertices = Floats(part.Vertices);
        var positions = new Point3DCollection(vertices.Length / 3);
        for (var i = 0; i < vertices.Length; i += 3)
            positions.Add(new(vertices[i], vertices[i + 1], vertices[i + 2]));
        var triangles = System.Runtime.InteropServices.MemoryMarshal.Cast<byte, int>(part.Triangles);
        var indices = new Int32Collection(triangles.Length);
        foreach (var index in triangles) indices.Add(index);
        var mesh = new MeshGeometry3D { Positions = positions, TriangleIndices = indices };
        if (part.Normals is not null)
        {
            var source = Floats(part.Normals);
            var normals = new Vector3DCollection(source.Length / 3);
            for (var i = 0; i < source.Length; i += 3)
                normals.Add(new(source[i], source[i + 1], source[i + 2]));
            mesh.Normals = normals;
        }
        if (part.Uv is not null)
        {
            var source = Floats(part.Uv);
            var uvs = new PointCollection(source.Length / 2);
            for (var i = 0; i < source.Length; i += 2)
                uvs.Add(new(source[i], 1 - source[i + 1]));
            mesh.TextureCoordinates = uvs;
        }
        mesh.Freeze();
        var m = part.Matrix;
        var transform = new MatrixTransform3D(new Matrix3D(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7],
            m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15]));
        transform.Freeze();
        return new GeometryModel3D(mesh, part.Legend is { } legend ? Glyph(legend) : Body(part.Color))
        {
            Transform = transform
        };
    }

    private static Material Body(double[]? value)
    {
        var color = value is [var red, var green, var blue]
            ? Color.FromRgb((byte)(red * 255), (byte)(green * 255), (byte)(blue * 255))
            : Colors.Black;
        var material = new MaterialGroup();
        material.Children.Add(new DiffuseMaterial(new SolidColorBrush(color)));
        material.Children.Add(new SpecularMaterial(new SolidColorBrush(Color.FromRgb(87, 87, 94)), 28));
        material.Children.Add(new EmissiveMaterial(Brushes.Black));
        return material;
    }

    private static Material Glyph(RemoteLegend legend)
    {
        var plate = new Grid { Width = 80, Height = 80, Background = Brushes.Transparent };
        if (!legend.Literal && Icon(legend.Text) is { } drawing)
        {
            plate.Children.Add(new System.Windows.Shapes.Path
            {
                Data = drawing, Stroke = Brushes.WhiteSmoke, StrokeThickness = 1.8,
                StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
                StrokeLineJoin = PenLineJoin.Round, Width = 56, Height = 56, Stretch = Stretch.Uniform,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
            });
        }
        else
        {
            plate.Children.Add(new TextBlock
            {
                Text = legend.Text, Foreground = Brushes.WhiteSmoke, FontSize = legend.Text.Length > 1 ? 22 : 44,
                FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center
            });
            if (legend.Secondary.Length > 0)
                plate.Children.Add(new TextBlock
                {
                    Text = legend.Secondary, Foreground = Brushes.LightBlue, FontSize = 18,
                    HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
                    Margin = new Thickness(0, 11, 9, 0)
                });
        }
        var group = new MaterialGroup();
        // The transparent diffuse base gives the emissive label its alpha mask.
        group.Children.Add(new DiffuseMaterial(Brushes.Transparent));
        group.Children.Add(new EmissiveMaterial(new VisualBrush(plate)));
        return group;
    }

    public static Geometry? Icon(string name)
    {
        var path = name switch
        {
            "power" => "M12,2 L12,11 M7,4 A8,8 0 1 0 17,4",
            "mic.fill" => "M9,5 A3,3 0 0 1 15,5 L15,12 A3,3 0 0 1 9,12 Z M5,10 L5,12 A7,7 0 0 0 19,12 L19,10 M12,19 L12,22 M8,22 L16,22",
            "house.fill" => "M2,11 L12,3 22,11 M5,10 L5,21 10,21 10,15 14,15 14,21 19,21 19,10",
            "speaker.slash.fill" => "M2,10 L6,10 11,5 11,19 6,14 2,14 Z M15,9 L21,15 M15,15 L21,9",
            "cursorarrow.motionlines" => "M10,3 L20,13 15,13 17,19 14,20 12,14 8,17 Z M2,5 L6,5 M1,10 L5,10 M2,15 L5,15",
            "line.3.horizontal" => "M4,6 L20,6 M4,12 L20,12 M4,18 L20,18",
            "arrow.left" => "M20,12 L4,12 10,6 M4,12 L10,18",
            "chevron.up" => "M5,16 L12,9 19,16",
            "chevron.down" => "M5,9 L12,16 19,9",
            "chevron.left" => "M16,5 L9,12 16,19",
            "chevron.right" => "M9,5 L16,12 9,19",
            "plus" => "M4,12 L20,12 M12,4 L12,20",
            "minus" => "M4,12 L20,12",
            "tv" => "M2,6 L22,6 22,18 2,18 Z M8,22 L16,22",
            "bolt.fill" => "M14,2 L5,14 11,14 9,22 19,10 13,10 Z",
            "circle.inset.filled" => "M12,3 A9,9 0 1 0 12,21 A9,9 0 1 0 12,3 M12,8 A4,4 0 1 0 12,16 A4,4 0 1 0 12,8",
            _ => null
        };
        return path is null ? null : Geometry.Parse(path);
    }
}
