// license:GPLv3+

// Compares the player's neutral cabinet fit (src/renderer/VisionCabinetFit.cpp) with the
// add-cabinet tool's Python fit, using the bundled GLB meshes. From the VPX checkout:
//
//   check_dir=$(mktemp -d)
//   xcrun clang++ -std=c++20 -O1 -Ithird-party/include -Isrc/renderer \
//     apps/visionos/Checks/CabinetFitChecks.cpp src/renderer/VisionCabinetFit.cpp -o "$check_dir/fit-check"
//   "$check_dir/fit-check" .
//
// CabinetFitGolden.json comes from tools/visionos/neutral_cabinet.py golden.

#include "VisionCabinetFit.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>

using namespace VisionCabinet;

namespace
{

int g_checks = 0;
int g_failures = 0;

void Check(bool ok, const std::string& what)
{
   ++g_checks;
   if (!ok && ++g_failures <= 40)
      fprintf(stderr, "FAIL %s\n", what.c_str());
}

bool Near(double a, double b, double tol) { return std::abs(a - b) <= tol; }

void CheckPoint(const Point& got, const nlohmann::json& want, double tol, const std::string& what)
{
   bool ok = want.is_array() && want.size() == 3;
   for (int i = 0; ok && i < 3; ++i)
      ok = Near(got[i], want[i].get<double>(), tol);
   char text[160];
   snprintf(text, sizeof text, " got (%.4f, %.4f, %.4f)", got[0], got[1], got[2]);
   Check(ok, what + text + " want " + want.dump());
}

nlohmann::json ReadJson(const std::string& path)
{
   std::ifstream file(path);
   if (!file)
   {
      fprintf(stderr, "Missing %s\n", path.c_str());
      exit(2);
   }
   return nlohmann::json::parse(file);
}

struct Mesh
{
   std::vector<Point> v;
   size_t triangles = 0;
};

// The decoding MeshGLTF.cpp's LoadGLB does for these files: metres (x, z, y) back to VPX units.
Mesh ReadGlb(const std::string& path)
{
   std::ifstream file(path, std::ios::binary);
   const std::vector<char> data((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
   Mesh mesh;
   uint32_t header[5];
   if (data.size() < sizeof header)
      return mesh;
   memcpy(header, data.data(), sizeof header);
   const auto doc = nlohmann::json::parse(data.begin() + 20, data.begin() + 20 + header[3]);
   const char* bin = data.data() + 20 + header[3] + 8;
   const auto& prim = doc["meshes"][0]["primitives"][0];
   const auto& acc = doc["accessors"][prim["attributes"]["POSITION"].get<int>()];
   const auto& view = doc["bufferViews"][acc["bufferView"].get<int>()];
   const size_t count = acc["count"].get<size_t>();
   const float* f = reinterpret_cast<const float*>(bin + view["byteOffset"].get<size_t>());
   constexpr double vpuToM = 0.0254 * 1.0625 / 50.0;
   for (size_t i = 0; i < count; ++i)
      mesh.v.push_back({ f[i * 3] / vpuToM, f[i * 3 + 2] / vpuToM, f[i * 3 + 1] / vpuToM });
   mesh.triangles = doc["accessors"][prim["indices"].get<int>()]["count"].get<size_t>() / 3;
   return mesh;
}

std::pair<Point, Point> Bounds(const std::vector<Point>& v)
{
   Point lo = v.front(), hi = v.front();
   for (const auto& p : v)
      for (int i = 0; i < 3; ++i)
      {
         lo[i] = std::min(lo[i], p[i]);
         hi[i] = std::max(hi[i], p[i]);
      }
   return { lo, hi };
}

Table ReadTable(const nlohmann::json& t)
{
   Table table;
   table.left = t["left"];
   table.top = t["top"];
   table.right = t["right"];
   table.bottom = t["bottom"];
   table.glassTop = t["glass_top"];
   table.glassBottom = t["glass_bottom"];
   table.slope = t["slope"];
   table.groundToLockbar = t["ground_to_lockbar"];
   if (t["plunger_x"].is_number())
      table.plungerX = t["plunger_x"].get<double>();
   return table;
}

} // namespace

int main(int argc, char** argv)
{
   const std::string root = argc > 1 ? argv[1] : ".";
   const std::string pack = root + "/src/assets/neutralCabinet/";
   Spec spec;
   Reference ref;
   Controls controls;
   std::string error;
   if (!LoadSpec(ReadJson(pack + "cabinet.json"), spec, error) || !LoadReference(ReadJson(pack + "reference.json"), ref, error)
      || !LoadControls(ReadJson(pack + "controls.json"), controls, error))
   {
      fprintf(stderr, "FAIL loading the pack: %s\n", error.c_str());
      return 1;
   }
   std::map<std::string, Mesh> meshes;
   for (const auto& part : spec.parts)
   {
      meshes[part.mesh] = ReadGlb(pack + "meshes/" + part.mesh + ".glb");
      Check(!meshes[part.mesh].v.empty(), "GLB " + part.mesh + " loads");
   }
   const auto golden = ReadJson(root + "/apps/visionos/Checks/CabinetFitGolden.json");
   const auto& probe = golden["probe"];

   int fits = 0;
   for (const auto& c : golden["fits"])
   {
      const std::string name = c["name"];
      const Table table = ReadTable(c["table"]);
      const Fit fit(ref, spec, table, c["clamp_glass"].get<bool>());
      if (c.contains("error"))
      {
         Check(fit.Error() == c["error"].get<std::string>(), name + ": rejected with \"" + c["error"].get<std::string>() + "\", got \"" + fit.Error() + "\"");
         continue;
      }
      Check(fit.Error().empty(), name + ": fits (" + fit.Error() + ")");
      if (!fit.Error().empty())
         continue;
      ++fits;
      const auto& v = c["values"];
      const std::pair<const char*, double> values[] = {
         { "sx_left", fit.Shift(Anchor::Left) }, { "sx_centre", fit.Shift(Anchor::Centre) }, { "sx_right", fit.Shift(Anchor::Right) },
         { "sy_front", fit.Shift(Anchor::Front) }, { "sy_back", fit.Shift(Anchor::Back) }, { "yf", fit.yFront }, { "yb", fit.yBack },
         { "glass_eff", fit.glassUsed }, { "pf_front_z", fit.playfieldFrontZ }, { "lockbar_z", fit.lockbarZ }, { "dz", fit.dz },
         { "rail_slope", fit.railSlope }, { "plunger_x", fit.plungerX } };
      for (const auto& [key, got] : values)
         Check(Near(got, v[key].get<double>(), key == std::string("rail_slope") ? 1e-6 : 1e-3), name + ": " + key + " " + std::to_string(got) + " want " + v[key].dump());
      Check(static_cast<int>(fit.Warnings().size()) == v["warnings"].get<int>(), name + ": warnings");
      for (size_t i = 0; i < probe.size(); ++i)
      {
         const Point p { probe[i][0], probe[i][1], probe[i][2] };
         CheckPoint(fit.MapBody(p), c["body"][i], 1e-3, name + ": body map " + probe[i].dump());
         CheckPoint(fit.MapHead(p), c["head"][i], 1e-3, name + ": head map " + probe[i].dump());
         CheckPoint(fit.MapLeg(p), c["legs"][i], 1e-3, name + ": leg map " + probe[i].dump());
      }
      const auto walls = fit.InnerWalls();
      for (size_t q = 0; q < walls.size(); ++q)
         for (size_t k = 0; k < 4; ++k)
            CheckPoint(walls[q].corners[k], c["walls"][q][k], 1e-3, name + ": inner wall " + std::to_string(q));

      // Fitted meshes, from the GLBs the player loads.
      for (const Variant variant : { Variant::Plunger, Variant::LaunchButton })
      {
         std::vector<Point> rails;
         for (const auto& part : spec.parts)
         {
            if (!part.InVariant(variant))
               continue;
            std::vector<Point> verts = meshes[part.mesh].v;
            const Point offset = FitVertices(fit, part, verts);
            const auto& want = c["parts"]["VRCab_" + part.name];
            const auto [lo, hi] = Bounds(verts);
            CheckPoint(lo, want["lo"], 0.01, name + ": " + part.name + " low bound");
            CheckPoint(hi, want["hi"], 0.01, name + ": " + part.name + " high bound");
            Check(meshes[part.mesh].triangles == want["triangles"].get<size_t>(), name + ": " + part.name + " triangles");
            if (part.deform == Deform::Rigid)
            {
               CheckPoint(offset, c["rigid"][part.name], 0.01, name + ": " + part.name + " rigid offset");
               const auto [l0, h0] = Bounds(meshes[part.mesh].v);
               for (int i = 0; i < 3; ++i)
                  Check(Near(h0[i] - l0[i], hi[i] - lo[i], 1e-6), name + ": " + part.name + " keeps its size");
            }
            if (part.name == "Rails")
               rails = verts;
            if (part.name == "Legs")
               Check(Near(lo[2], 0.0, 1e-3), name + ": feet on the floor");
            if (part.name == "Body")
            {
               // The donor's bottom is level within 16 VPU.
               double minY = 1e9, maxY = -1e9;
               for (const auto& p : verts)
                  if (p[2] < lo[2] + 25.0)
                  {
                     minY = std::min(minY, p[1]);
                     maxY = std::max(maxY, p[1]);
                  }
               Check(maxY - minY > 0.8 * (hi[1] - lo[1]) && lo[2] > 0, name + ": cabinet bottom stays level above the floor");
            }
         }
         // Rails run parallel to the playfield for a flat glass.
         if (variant == Variant::Plunger && table.glassTop == table.glassBottom && !rails.empty())
         {
            double y0 = 1e9;
            for (const auto& p : rails)
               if (p[0] > 500)
                  y0 = std::min(y0, p[1]);
            Point back { 0, 0, -1e9 }, front { 0, 0, -1e9 };
            for (const auto& p : rails)
            {
               if (p[0] <= 500)
                  continue;
               if (p[1] < y0 + 250 && p[2] > back[2])
                  back = p;
               if (p[1] > fit.yFront - 100 && p[2] > front[2])
                  front = p;
            }
            const double angle = atan((back[2] - front[2]) / (front[1] - back[1])) * 180.0 / 3.14159265358979323846;
            Check(Near(angle, table.slope, 0.5), name + ": rail mesh angle " + std::to_string(angle));
            Check(Near(fit.RailTopZ(fit.yFront) - fit.PlayfieldZ(fit.yFront), fit.RailTopZ(fit.yBack) - fit.PlayfieldZ(fit.yBack), 2),
               name + ": equal depth under the rails");
         }
      }
      // Control anchors move with their meshes.
      for (const ButtonAnchor* a : { &controls.start, &controls.coin, &controls.plunger, &controls.launch })
      {
         const auto part = std::ranges::find_if(spec.parts, [a](const PartSpec& p) { return p.name == a->part; });
         Check(part != spec.parts.end() && part->deform == Deform::Rigid, name + ": " + a->part + " anchor is on a rigid part");
         const Point fitted = FitPoint(fit, *part, c["rigid"][part->name].is_array()
            ? Point { c["rigid"][part->name][0], c["rigid"][part->name][1], c["rigid"][part->name][2] } : Point {}, a->point);
         const Point moved { a->point[0] + c["rigid"][part->name][0].get<double>(), a->point[1] + c["rigid"][part->name][1].get<double>(),
            a->point[2] + c["rigid"][part->name][2].get<double>() };
         CheckPoint(fitted, nlohmann::json { moved[0], moved[1], moved[2] }, 1e-6, name + ": " + a->part + " anchor");
      }
      // Monotonic slices.
      double lastX = -1e9, lastY = -1e9;
      bool monotonic = true;
      for (double x = -200; x < 1300; x += 5)
      {
         monotonic &= fit.MapX(x) > lastX;
         lastX = fit.MapX(x);
      }
      for (double y = -500; y < 2300; y += 5)
      {
         monotonic &= fit.MapY(y) > lastY;
         lastY = fit.MapY(y);
      }
      Check(monotonic, name + ": monotonic slices");
   }

   for (const auto& c : golden["variants"])
   {
      std::vector<PlungerInfo> plungers;
      for (const auto& p : c["plungers"])
         plungers.push_back({ p["name"], p.value("auto_plunger", false), p.value("is_visible", true), 0.0 });
      std::string reason;
      const Variant v = ChooseVariant(plungers, reason);
      Check((v == Variant::Plunger ? "plunger" : "launch-button") == c["variant"].get<std::string>(), "variant for " + c["plungers"].dump());
   }

   for (const auto& c : golden["glass"])
   {
      // The same item rules VRDeviceVision.cpp applies to the loaded table (glass.py's choose()).
      const std::string name = c["name"];
      GlassInput in;
      in.tableArea = c["size"][0].get<double>() * c["size"][1].get<double>();
      in.legacy = c["version"].get<int>() < 1080;
      in.glassTop = c["glass_top"];
      in.glassBottom = c["glass_bottom"].is_number() ? c["glass_bottom"].get<double>() : in.glassTop;
      const auto lower = [](std::string s) { for (auto& ch : s) ch = static_cast<char>(tolower(ch)); return s; };
      std::vector<std::string> used;
      for (const auto& item : c["items"])
         if (item.contains("surface") && !item["surface"].get<std::string>().empty())
            used.push_back(lower(item["surface"]));
      for (const auto& item : c["items"])
      {
         const std::string kind = item["kind"];
         const bool referenced = std::ranges::find(used, lower(item["name"])) != used.end();
         if (kind == "Wall" && referenced)
         {
            std::vector<std::array<double, 2>> pts;
            for (const auto& p : item.value("drag_points", nlohmann::json::array()))
               pts.push_back({ p["x"].get<double>(), p["y"].get<double>() });
            in.referencedWalls.push_back({ item["name"], item.value("height_top", 0.0), PolygonArea(pts) });
         }
         if (kind == "Ramp")
         {
            const double h = std::max(item["height_top"].get<double>(), item["height_bottom"].get<double>());
            if (referenced)
               in.reach.emplace_back(h, item["name"]);
            if (item.value("is_collidable", true))
               in.reach.emplace_back(h, item["name"]);
         }
      }
      const GlassChoice g = ChooseGlass(in, 8.0);
      Check(g.height == c["new"].get<double>(), name + ": glass " + std::to_string(g.height) + " want " + c["new"].dump());
      Check(g.mainSurface == c["main_surface"].get<double>(), name + ": main surface");
      Check(g.limitedBy == (c["limited_by"].is_string() ? c["limited_by"].get<std::string>() : std::string()), name + ": limited by " + g.limitedBy);
      const auto& fields = c["fields"];
      if (in.legacy)
         Check(fields.size() == 1 && g.newTop == fields["glass_top_height"].get<double>() && g.newBottom == g.newTop, name + ": legacy fields");
      else
      {
         Check(g.newBottom == fields["glass_bottom_height"].get<double>(), name + ": bottom glass");
         Check(g.newTop == (fields.contains("glass_top_height") ? fields["glass_top_height"].get<double>() : in.glassTop), name + ": top glass");
      }
   }

   printf("%s: %d of %d cabinet fit checks passed (%d fitted cases, %zu probe points each)\n", g_failures ? "FAILED" : "passed",
      g_checks - g_failures, g_checks, fits, probe.size());
   return g_failures ? 1 : 0;
}
