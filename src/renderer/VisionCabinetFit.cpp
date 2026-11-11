// license:GPLv3+

#include "VisionCabinetFit.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace VisionCabinet
{

namespace
{

double Lerp(double a, double b, double t) { return a + (b - a) * t; }
double Clamp(double v, double lo, double hi) { return v < lo ? lo : v > hi ? hi : v; }

bool ParseAnchor(const std::string& name, Anchor& anchor)
{
   if (name == "left") anchor = Anchor::Left;
   else if (name == "centre") anchor = Anchor::Centre;
   else if (name == "right") anchor = Anchor::Right;
   else if (name == "front") anchor = Anchor::Front;
   else if (name == "back") anchor = Anchor::Back;
   else if (name == "plunger") anchor = Anchor::Plunger;
   else return false;
   return true;
}

bool ParseColor(const nlohmann::json& value, unsigned int& color)
{
   if (!value.is_string())
      return false;
   const std::string text = value.get<std::string>();
   if (text.size() != 7 || text[0] != '#')
      return false;
   char* end = nullptr;
   color = static_cast<unsigned int>(strtoul(text.c_str() + 1, &end, 16));
   return end == text.c_str() + 7;
}

bool ReadPoint(const nlohmann::json& value, Point& point)
{
   if (!value.is_array() || value.size() != 3)
      return false;
   for (size_t i = 0; i < 3; ++i)
   {
      if (!value[i].is_number())
         return false;
      point[i] = value[i].get<double>();
   }
   return true;
}

bool ReadPair(const nlohmann::json& value, std::array<double, 2>& pair)
{
   if (!value.is_array() || value.size() != 2 || !value[0].is_number() || !value[1].is_number())
      return false;
   pair = { value[0].get<double>(), value[1].get<double>() };
   return true;
}

bool ReadKnots(const nlohmann::json& value, std::vector<Knot>& knots)
{
   if (!value.is_array() || value.size() < 2)
      return false;
   for (const auto& knot : value)
   {
      Anchor anchor;
      if (!knot.is_array() || knot.size() != 2 || !knot[0].is_number() || !knot[1].is_string() || !ParseAnchor(knot[1].get<std::string>(), anchor))
         return false;
      knots.push_back({ knot[0].get<double>(), anchor });
   }
   return true;
}

} // namespace

bool PartSpec::InVariant(Variant variant) const
{
   return variants.empty() || std::ranges::find(variants, variant) != variants.end();
}

bool LoadSpec(const nlohmann::json& cabinet, Spec& spec, std::string& error)
{
   spec = {};
   if (!cabinet.is_object() || !ReadKnots(cabinet.value("x_knots", nlohmann::json()), spec.xKnots)
      || !ReadKnots(cabinet.value("y_knots", nlohmann::json()), spec.yKnots)
      || !ReadPair(cabinet.value("leg_knots", nlohmann::json()), spec.legKnots)
      || !ReadPair(cabinet.value("glass_clamp", nlohmann::json()), spec.glassClamp))
   {
      error = "cabinet.json has no valid knots or glass clamp";
      return false;
   }
   const auto& parts = cabinet.value("parts", nlohmann::json());
   if (!parts.is_array() || parts.empty())
   {
      error = "cabinet.json lists no parts";
      return false;
   }
   for (const auto& p : parts)
   {
      PartSpec part;
      part.name = p.value("name", std::string());
      part.mesh = p.value("mesh", std::string());
      part.material = p.value("material", std::string());
      part.image = p.value("image", std::string());
      const std::string group = p.value("group", std::string());
      const std::string deform = p.value("deform", std::string());
      part.feet = group == "feet";
      if (deform == "field") part.deform = Deform::Field;
      else if (deform == "head") part.deform = Deform::Head;
      else if (deform == "legs") part.deform = Deform::Legs;
      else if (deform == "rigid") part.deform = Deform::Rigid;
      else
      {
         error = "cabinet.json part " + part.name + " has an unknown deformation " + deform;
         return false;
      }
      if (part.deform == Deform::Rigid && !ParseAnchor(p.value("anchor", std::string()), part.anchor))
      {
         error = "cabinet.json rigid part " + part.name + " has no anchor";
         return false;
      }
      if (p.contains("variants"))
      {
         for (const auto& v : p["variants"])
         {
            const std::string name = v.is_string() ? v.get<std::string>() : std::string();
            if (name == "plunger") part.variants.push_back(Variant::Plunger);
            else if (name == "launch-button") part.variants.push_back(Variant::LaunchButton);
            else
            {
               error = "cabinet.json part " + part.name + " names an unknown variant";
               return false;
            }
         }
      }
      if (part.name.empty() || part.mesh.empty() || part.material.empty() || (group != "cabinet" && group != "feet"))
      {
         error = "cabinet.json has an incomplete part";
         return false;
      }
      spec.parts.push_back(part);
   }
   const auto& materials = cabinet.value("materials", nlohmann::json());
   if (!materials.is_object())
   {
      error = "cabinet.json has no materials";
      return false;
   }
   for (const auto& [name, m] : materials.items())
   {
      MaterialSpec mat;
      mat.name = name;
      mat.metal = m.value("type", std::string()) == "metal";
      if (!ParseColor(m.value("base_color", nlohmann::json()), mat.baseColor) || !ParseColor(m.value("glossy_color", nlohmann::json()), mat.glossyColor)
         || !ParseColor(m.value("clearcoat_color", nlohmann::json()), mat.clearcoatColor))
      {
         error = "cabinet.json material " + name + " has an invalid colour";
         return false;
      }
      mat.wrapLighting = m.value("wrap_lighting", 0.f);
      mat.roughness = m.value("roughness", 0.f);
      mat.glossyImageLerp = m.value("glossy_image_lerp", 1.f);
      mat.edge = m.value("edge", 1.f);
      mat.edgeAlpha = m.value("edge_alpha", 1.f);
      mat.opacity = m.value("opacity", 1.f);
      mat.opacityActive = m.value("opacity_active", false);
      mat.thickness = m.value("thickness", 0.05f);
      spec.materials.push_back(mat);
   }
   const auto& images = cabinet.value("images", nlohmann::json());
   if (images.is_object())
      for (const auto& [name, file] : images.items())
         if (file.is_string())
            spec.images.emplace_back(name, file.get<std::string>());
   for (const auto& part : spec.parts)
   {
      if (std::ranges::none_of(spec.materials, [&part](const MaterialSpec& m) { return m.name == part.material; })
         || (!part.image.empty() && std::ranges::none_of(spec.images, [&part](const auto& i) { return i.first == part.image; })))
      {
         error = "cabinet.json part " + part.name + " uses a missing material or image";
         return false;
      }
   }
   return true;
}

bool LoadReference(const nlohmann::json& reference, Reference& ref, std::string& error)
{
   const auto& r = reference.is_object() ? reference.value("reference", nlohmann::json()) : nlohmann::json();
   const auto& dp = r.is_object() ? r.value("donor_playfield", nlohmann::json()) : nlohmann::json();
   const auto number = [](const nlohmann::json& o, const char* key, double& out)
   {
      if (!o.is_object() || !o.contains(key) || !o[key].is_number())
         return false;
      out = o[key].get<double>();
      return true;
   };
   if (!number(dp, "width", ref.donorWidth) || !number(dp, "length", ref.donorLength) || !number(r, "playfield_front_y", ref.playfieldFrontY)
      || !number(r, "playfield_back_y", ref.playfieldBackY) || !number(r, "lockbar_top_z", ref.lockbarTopZ)
      || !number(r, "lockbar_bottom_z", ref.lockbarBottomZ) || !number(r, "lockbar_inner_y", ref.lockbarInnerY) || !number(r, "rail_front_z", ref.railFrontZ) || !number(r, "rail_slope", ref.railSlope)
      || !number(r, "body_bottom_z", ref.bodyBottomZ) || !ReadPair(r.value("launch_axis", nlohmann::json()), ref.launchAxis))
   {
      error = "reference.json is incomplete";
      return false;
   }
   return true;
}

bool LoadControls(const nlohmann::json& controls, Controls& out, std::string& error)
{
   const auto anchor = [&controls](const char* key, ButtonAnchor& a, bool face)
   {
      if (!controls.is_object() || !controls.contains(key))
         return false;
      const auto& c = controls[key];
      a.part = c.value("part", std::string());
      return !a.part.empty() && ReadPoint(c.value("point", nlohmann::json()), a.point) && (!face || ReadPair(c.value("half", nlohmann::json()), a.half));
   };
   const auto& t = controls.is_object() ? controls.value("translite", nlohmann::json()) : nlohmann::json();
   if (!anchor("start", out.start, true) || !anchor("coin", out.coin, true) || !anchor("leftFlipper", out.leftFlipper, false)
      || !anchor("rightFlipper", out.rightFlipper, false) || !anchor("plunger", out.plunger, false) || !anchor("launch", out.launch, true)
      || !t.is_object() || !t.contains("front_y_top") || !t.contains("front_y_bottom") || !t.contains("glass") || !t.contains("window")
      || !ReadPair(t["glass"].value("x", nlohmann::json()), out.glassX) || !ReadPair(t["glass"].value("z", nlohmann::json()), out.glassZ)
      || !ReadPair(t["window"].value("x", nlohmann::json()), out.windowX) || !ReadPair(t["window"].value("z", nlohmann::json()), out.windowZ))
   {
      error = "controls.json is incomplete";
      return false;
   }
   out.transliteFrontYTop = t["front_y_top"].get<double>();
   out.transliteFrontYBottom = t["front_y_bottom"].get<double>();
   return true;
}

Fit::Fit(const Reference& ref, const Spec& spec, const Table& table, bool clampGlass)
   : m_ref(ref)
   , m_spec(spec)
   , m_table(table)
{
   theta = table.slope * (3.14159265358979323846 / 180.0);
   m_sxLeft = table.left;
   m_sxRight = table.right - ref.donorWidth;
   m_sxCentre = (table.left + table.right) / 2 - ref.donorWidth / 2;
   yFront = table.bottom;
   yBack = table.bottom - table.Length() * cos(theta);
   // The lockbar's inner edge reaches just over the playfield's front edge, as on a real cabinet.
   yAnchor = ref.lockbarInnerY + LockbarOverlap;
   railAnchorZ = ref.railFrontZ - ref.railSlope * (yAnchor - ref.playfieldFrontY);
   m_syFront = yFront - yAnchor;
   m_syBack = yBack - ref.playfieldBackY;

   const double lo = clampGlass ? spec.glassClamp[0] : -1e9;
   const double hi = clampGlass ? spec.glassClamp[1] : 1e9;
   const double gb = table.glassBottom;
   glassUsed = Clamp(gb, lo, hi);
   if (glassUsed != gb)
   {
      char text[200];
      snprintf(text, sizeof text, "glass height at the lockbar is %.0f VPU; the cabinet uses %.0f", gb, glassUsed);
      m_warnings.emplace_back(text);
   }
   playfieldFrontZ = table.groundToLockbar - gb;
   lockbarZ = playfieldFrontZ + glassUsed;
   dz = lockbarZ - ref.lockbarTopZ;
   // The side rails follow the glass: parallel to the playfield for a flat glass.
   const double topUsed = std::max(table.glassTop - (gb - glassUsed), glassUsed);
   railSlope = (table.Length() * sin(theta) + topUsed - glassUsed) / (table.Length() * cos(theta));

   const double spanLo = (table.left + table.right) / 2 + 402.0;
   const double spanHi = table.right - 41.0;
   const double defaultX = table.right - (ref.donorWidth - ref.launchAxis[0]);
   const double px = table.plungerX.value_or(defaultX);
   plungerX = spanLo <= spanHi ? Clamp(px, spanLo, spanHi) : defaultX;

   for (const auto* knots : { &spec.xKnots, &spec.yKnots })
   {
      for (size_t i = 1; i < knots->size(); ++i)
      {
         const Knot& a = (*knots)[i - 1];
         const Knot& b = (*knots)[i];
         if (b.position + Shift(b.anchor) <= a.position + Shift(a.anchor))
         {
            m_error = knots == &spec.xKnots ? "table width is too far from the reference cabinet to fit it"
                                            : "table length is too far from the reference cabinet to fit it";
            return;
         }
      }
   }
   if (spec.legKnots[1] + dz <= spec.legKnots[0] + 20)
      m_error = "lockbar would sit too low for the legs";
   else if (!std::isfinite(railSlope) || table.Length() <= 0 || table.Width() <= 0)
      m_error = "table has no usable playfield size";
}

double Fit::Shift(Anchor anchor) const
{
   switch (anchor)
   {
   case Anchor::Left: return m_sxLeft;
   case Anchor::Right: return m_sxRight;
   case Anchor::Centre: return m_sxCentre;
   case Anchor::Front: return m_syFront;
   case Anchor::Back: return m_syBack;
   case Anchor::Plunger: return plungerX - m_ref.launchAxis[0];
   }
   return 0;
}

double Fit::Piecewise(double v, const std::vector<Knot>& knots) const
{
   if (v <= knots.front().position)
      return Shift(knots.front().anchor);
   for (size_t i = 1; i < knots.size(); ++i)
   {
      const Knot& a = knots[i - 1];
      const Knot& b = knots[i];
      if (v <= b.position)
         return Lerp(Shift(a.anchor), Shift(b.anchor), (v - a.position) / (b.position - a.position));
   }
   return Shift(knots.back().anchor);
}

double Fit::MapX(double x) const { return x + Piecewise(x, m_spec.xKnots); }
double Fit::MapY(double y) const { return y + Piecewise(y, m_spec.yKnots); }

double Fit::Shear(double ySource, double yDest) const
{
   return railSlope * std::max(0.0, yFront - yDest) - m_ref.railSlope * std::max(0.0, yAnchor - ySource);
}

double Fit::ShearWeight(double y, double z) const
{
   const double top = railAnchorZ + m_ref.railSlope * std::max(0.0, yAnchor - y);
   const double bottom = m_ref.bodyBottomZ;
   return Clamp((z - bottom) / std::max(1.0, top - bottom), 0.0, 1.0);
}

Point Fit::MapBody(const Point& p) const
{
   const double y2 = MapY(p[1]);
   return { MapX(p[0]), y2, p[2] + dz + Shear(p[1], y2) * ShearWeight(p[1], p[2]) };
}

Point Fit::MapHead(const Point& p) const
{
   return { MapX(p[0]), p[1] + m_syBack, p[2] + dz + Shear(m_ref.playfieldBackY, yBack) };
}

Point Fit::MapLeg(const Point& p) const
{
   const double dx = p[0] < m_ref.donorWidth / 2 ? m_sxLeft : m_sxRight;
   const double dy = p[1] > m_ref.playfieldFrontY / 2 ? m_syFront : m_syBack;
   const double z0 = m_spec.legKnots[0], z1 = m_spec.legKnots[1];
   double z2;
   if (p[2] <= z0)
      z2 = p[2];
   else if (p[2] >= z1)
      z2 = p[2] + dz;
   else
      z2 = z0 + (p[2] - z0) * (z1 + dz - z0) / (z1 - z0);
   return { p[0] + dx, p[1] + dy, z2 };
}

Point Fit::RigidOffset(const Point& centre, Anchor anchor) const
{
   const double dx = anchor == Anchor::Plunger ? plungerX - m_ref.launchAxis[0] : Shift(anchor);
   const Point b = MapBody(centre);
   return { dx, b[1] - centre[1], b[2] - centre[2] };
}

Point Fit::Map(Deform deform, const Point& p) const
{
   switch (deform)
   {
   case Deform::Head: return MapHead(p);
   case Deform::Legs: return MapLeg(p);
   default: return MapBody(p);
   }
}

double Fit::PlayfieldZ(double y) const { return playfieldFrontZ + (yFront - y) * tan(theta); }

double Fit::RailTopZ(double y) const { return railAnchorZ + dz + railSlope * std::max(0.0, yFront - y); }

std::vector<Fit::Quad> Fit::InnerWalls() const
{
   const double l = m_table.left - 1.0, r = m_table.right + 1.0;
   const double yb = yBack - 1.0, yf = yFront;
   constexpr double drop = 30.0, railIn = 40.0;
   const double lockBottom = m_ref.lockbarBottomZ + dz + 5.0;
   const double yfw = yFront + 1.0; // closes the playfield's front edge under the lockbar
   return {
      { { { { l, yb, PlayfieldZ(yb) - drop }, { l, yfw, PlayfieldZ(yf) - drop }, { l, yfw, RailTopZ(yf) - railIn }, { l, yb, RailTopZ(yb) - railIn } } }, { 1, 0, 0 } },
      { { { { r, yfw, PlayfieldZ(yf) - drop }, { r, yb, PlayfieldZ(yb) - drop }, { r, yb, RailTopZ(yb) - railIn }, { r, yfw, RailTopZ(yf) - railIn } } }, { -1, 0, 0 } },
      { { { { r, yb, PlayfieldZ(yb) - drop }, { l, yb, PlayfieldZ(yb) - drop }, { l, yb, RailTopZ(yb) - railIn }, { r, yb, RailTopZ(yb) - railIn } } }, { 0, 1, 0 } },
      { { { { l, yfw, PlayfieldZ(yf) - drop }, { r, yfw, PlayfieldZ(yf) - drop }, { r, yfw, lockBottom }, { l, yfw, lockBottom } } }, { 0, -1, 0 } },
   };
}

Point FitVertices(const Fit& fit, const PartSpec& part, std::vector<Point>& vertices)
{
   if (part.deform != Deform::Rigid)
   {
      for (auto& v : vertices)
         v = fit.Map(part.deform, v);
      return {};
   }
   if (vertices.empty())
      return {};
   Point lo = vertices.front(), hi = vertices.front();
   for (const auto& v : vertices)
      for (int i = 0; i < 3; ++i)
      {
         lo[i] = std::min(lo[i], v[i]);
         hi[i] = std::max(hi[i], v[i]);
      }
   const Point offset = fit.RigidOffset({ (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2 }, part.anchor);
   for (auto& v : vertices)
      for (int i = 0; i < 3; ++i)
         v[i] += offset[i];
   return offset;
}

Point FitPoint(const Fit& fit, const PartSpec& part, const Point& rigidOffset, const Point& point)
{
   if (part.deform == Deform::Rigid)
      return { point[0] + rigidOffset[0], point[1] + rigidOffset[1], point[2] + rigidOffset[2] };
   return fit.Map(part.deform, point);
}

Variant ChooseVariant(const std::vector<PlungerInfo>& plungers, std::string& reason)
{
   if (plungers.empty())
   {
      reason = "the table has no plunger object";
      return Variant::LaunchButton;
   }
   for (const auto& p : plungers)
   {
      if (!p.autoPlunger && p.visible)
      {
         reason = "it has a manual plunger (" + p.name + ")";
         return Variant::Plunger;
      }
   }
   reason = "its only plunger is an auto-plunger or hidden";
   return Variant::LaunchButton;
}

std::optional<double> PlungerX(const std::vector<PlungerInfo>& plungers)
{
   for (const auto& p : plungers)
      if (!p.autoPlunger)
         return p.x;
   return std::nullopt;
}

double PolygonArea(const std::vector<std::array<double, 2>>& points)
{
   if (points.size() < 3)
      return 0;
   double a = 0;
   for (size_t i = 0; i < points.size(); ++i)
   {
      const auto& p = points[i];
      const auto& q = points[(i + 1) % points.size()];
      a += p[0] * q[1] - q[0] * p[1];
   }
   return std::abs(a) / 2;
}

GlassChoice ChooseGlass(const GlassInput& input, double depthCm)
{
   constexpr double ball = 50.0, margin = 25.0;
   GlassChoice out;
   std::vector<std::pair<double, std::string>> reach { { 0.0, "playfield" } };
   for (const auto& wall : input.referencedWalls)
   {
      reach.emplace_back(wall.heightTop, wall.name);
      if (wall.polygonArea > 0.5 * input.tableArea && wall.heightTop > out.mainSurface)
      {
         out.mainSurface = wall.heightTop;
         out.mainSurfaceName = wall.name;
      }
   }
   reach.insert(reach.end(), input.reach.begin(), input.reach.end());
   // Same order as Python's max() over (height, name) tuples.
   const auto top = *std::ranges::max_element(reach);
   out.ceiling = top.first + ball + margin;
   const double target = out.mainSurface + depthCm * vpuPerCm;
   out.height = std::nearbyint(std::max(target, out.ceiling)); // round half to even, like Python's round()
   if (out.ceiling > target)
      out.limitedBy = top.second;
   if (input.legacy)
      out.newTop = out.newBottom = out.height;
   else
   {
      out.newBottom = out.height;
      out.newTop = input.glassTop < out.height ? out.height : input.glassTop;
   }
   return out;
}

} // namespace VisionCabinet
