// license:GPLv3+

#pragma once

// Fitting the neutral VR cabinet (src/assets/neutralCabinet) to a table.
//
// This is a port of the add-cabinet tool's fit (add_cabinet/fit.py and glass.py in
// https://github.com/astromaddie/vpx-cabinet), kept free of VPX types so the Mac check in
// apps/visionos/Checks/CabinetFitChecks.cpp can compare it with the Python results.
//
// Everything is in VPX cabinet space: VPX units, x right and y toward the player like the
// playfield, z up from the cabinet floor. The playfield is tilted by its slope about its
// front edge, which sits at z = groundToLockbar - glassBottom. The fit is 9-slice style:
// plain panels, rails and the lockbar stretch, hardware only moves, the rails follow the
// playfield and the cabinet bottom stays level on legs of equal length.

#include <array>
#include <optional>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace VisionCabinet
{

using Point = std::array<double, 3>;

constexpr double vpuPerCm = 50.0 / (2.54 * 1.0625);

enum class Anchor { Left, Centre, Right, Front, Back, Plunger };
enum class Deform { Field, Head, Legs, Rigid };
enum class Variant { Plunger, LaunchButton };

struct Knot
{
   double position;
   Anchor anchor;
};

struct PartSpec
{
   std::string name, mesh, material, image;
   bool feet = false; // cabinet feet part group rather than the cabinet one
   Deform deform = Deform::Field;
   Anchor anchor = Anchor::Centre; // rigid parts only
   std::vector<Variant> variants; // empty: both
   bool InVariant(Variant variant) const;
};

struct MaterialSpec
{
   std::string name;
   bool metal = false;
   unsigned int baseColor = 0, glossyColor = 0, clearcoatColor = 0; // 0xRRGGBB
   float wrapLighting = 0.f, roughness = 0.f, glossyImageLerp = 1.f, edge = 1.f, edgeAlpha = 1.f, opacity = 1.f, thickness = 0.05f;
   bool opacityActive = false;
};

struct Spec
{
   std::vector<Knot> xKnots, yKnots;
   std::array<double, 2> legKnots {};
   std::array<double, 2> glassClamp {};
   std::vector<PartSpec> parts;
   std::vector<MaterialSpec> materials;
   std::vector<std::pair<std::string, std::string>> images; // image name, file name
};

// The donor cabinet frame, from reference.json.
struct Reference
{
   double donorWidth = 0, donorLength = 0;
   double playfieldFrontY = 0, playfieldBackY = 0;
   double lockbarTopZ = 0, lockbarBottomZ = 0;
   double railFrontZ = 0, railSlope = 0;
   double bodyBottomZ = 0;
   std::array<double, 2> launchAxis {};
};

struct ButtonAnchor
{
   std::string part;
   Point point {};
   std::array<double, 2> half {}; // x and z half extents, zero for points
};

// Control anchors and display regions measured from the meshes (controls.json).
struct Controls
{
   ButtonAnchor start, coin, leftFlipper, rightFlipper, plunger, launch;
   double transliteFrontYTop = 0, transliteFrontYBottom = 0;
   std::array<double, 2> glassX {}, glassZ {}, windowX {}, windowZ {};
};

bool LoadSpec(const nlohmann::json& cabinet, Spec& spec, std::string& error);
bool LoadReference(const nlohmann::json& reference, Reference& ref, std::string& error);
bool LoadControls(const nlohmann::json& controls, Controls& out, std::string& error);

struct Table
{
   double left = 0, top = 0, right = 0, bottom = 0;
   double glassTop = 0, glassBottom = 0; // glassBottom as VPX uses it (a copy of the top glass before 10.8)
   double slope = 0; // degrees
   double groundToLockbar = 0;
   std::optional<double> plungerX;
   double Width() const { return right - left; }
   double Length() const { return bottom - top; }
};

class Fit
{
public:
   Fit(const Reference& ref, const Spec& spec, const Table& table, bool clampGlass);

   // Empty when the table can be fitted.
   const std::string& Error() const { return m_error; }
   const std::vector<std::string>& Warnings() const { return m_warnings; }

   Point MapBody(const Point& p) const;
   Point MapHead(const Point& p) const;
   Point MapLeg(const Point& p) const;
   Point RigidOffset(const Point& centre, Anchor anchor) const;
   Point Map(Deform deform, const Point& p) const; // field, head or legs

   double PlayfieldZ(double y) const;
   double RailTopZ(double y) const;
   // Quads lining the inside of the cabinet: corners and the inward normal, in the
   // tool's order (left, right, back, front).
   struct Quad
   {
      std::array<Point, 4> corners;
      Point normal;
   };
   std::vector<Quad> InnerWalls() const;

   double Shift(Anchor anchor) const; // the x or y shift of a knot anchor, or the plunger's x shift
   double MapX(double x) const;
   double MapY(double y) const;

   double yFront = 0, yBack = 0;
   double glassUsed = 0, playfieldFrontZ = 0, lockbarZ = 0, dz = 0;
   double railSlope = 0;
   double plungerX = 0;
   double theta = 0;

private:
   double Shear(double ySource, double yDest) const;
   double ShearWeight(double y, double z) const;
   double Piecewise(double v, const std::vector<Knot>& knots) const;

   const Reference& m_ref;
   const Spec& m_spec;
   Table m_table;
   double m_sxLeft = 0, m_sxCentre = 0, m_sxRight = 0, m_syFront = 0, m_syBack = 0;
   std::string m_error;
   std::vector<std::string> m_warnings;
};

// Moves one part's vertices as the tool does: rigid parts by the offset of their bounding
// box centre, the others through their map. Returns the rigid offset, zero otherwise.
Point FitVertices(const Fit& fit, const PartSpec& part, std::vector<Point>& vertices);

// Moves a point on a part (a control anchor) with the same fit as the part's mesh.
Point FitPoint(const Fit& fit, const PartSpec& part, const Point& rigidOffset, const Point& point);

struct PlungerInfo
{
   std::string name;
   bool autoPlunger = false;
   bool visible = true;
   double x = 0;
};

Variant ChooseVariant(const std::vector<PlungerInfo>& plungers, std::string& reason);
// The tool takes the first non-automatic plunger's x for the hardware, visible or not.
std::optional<double> PlungerX(const std::vector<PlungerInfo>& plungers);

// The glass rule: 8 cm above the main playfield surface, never below what the ball can reach.
struct GlassWall
{
   std::string name;
   double heightTop = 0;
   double polygonArea = 0; // shoelace area of the drag points, 0 with fewer than three
};

struct GlassInput
{
   double tableArea = 0;
   bool legacy = false; // file version before 10.8
   double glassTop = 0, glassBottom = 0; // as stored in the file (glassBottom unused when legacy)
   std::vector<GlassWall> referencedWalls; // walls named as a surface by kickers, triggers, flippers...
   std::vector<std::pair<double, std::string>> reach; // referenced and collidable ramps, ramp primitives
};

struct GlassChoice
{
   double height = 0; // the new glass height at the lockbar
   double mainSurface = 0;
   std::string mainSurfaceName;
   double ceiling = 0;
   std::string limitedBy; // empty when the 8 cm target won
   double newTop = 0, newBottom = 0; // the table's glass fields after the change, as VPX uses them
};

GlassChoice ChooseGlass(const GlassInput& input, double depthCm);

double PolygonArea(const std::vector<std::array<double, 2>>& points);

} // namespace VisionCabinet
