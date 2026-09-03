import QtQuick
import qs.Common

  // Hexagonal sphere logo: a Goldberg polyhedron (12 pentagons + 80
  // hexagons, 270 edges), built once; a FrameAnimation tumbles it with
  // an orthographic projection, edges drawn in three depth tiers.
Item {
    id: root

    property real radius: 66
    property real strokeWidth: 1.5
    property color edgeColor: Theme.primary
    property real yawRate: 10
    property real pitchRate: 3
    // Geodesic subdivision frequency: cells = 10F²+2 (12 pentagons +
    // (10F²-10) hexagons), edges = 30F². Lower F = chunkier cells.
    property int subdivisions: 3
    // false = decorative (status row): hover glow and tap disabled
    property bool interactive: true

    width: radius * 2 + strokeWidth * 2
    height: radius * 2 + strokeWidth * 2

    property var _geo: null
    property var _baseVerts: []     // 180 unit centroids
    property var _edges: []         // 270 × 2 centroid indices
    property var _t: 0

    // ── Hover ─────────────────────────────────────────────────────
    // Hover: wander (random tumble target) + brighten; idle: calm spin.
    property bool hovered: false
    property real _hover: 0
    Behavior on _hover { NumberAnimation { duration: 250 } }
    property real _vx: yawRate      // current deg/s (yaw, pitch)
    property real _vy: pitchRate
    property real _angY: 0
    property real _angP: 0
    property real _lastT: -1
    // Hover phase: one direction, exponential speed profile
    // base → peak → back to base, then a new direction kicks off.
    property real _phaseT: 0
    property real _phaseDur: 2.4
    property real _dir: 0
    property real _peak: 550
    // Heartbeat pulse (0..1), tapped into a lub-dub swell that drives
    // the effective drawn radius in _tick.
    property real _pulse: 0
    SequentialAnimation {
        id: heartbeat
        running: false
        NumberAnimation { target: root; property: "_pulse"; to: 1; duration: 120; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "_pulse"; to: 0.25; duration: 110; easing.type: Easing.InQuad }
        PauseAnimation { duration: 90 }
        NumberAnimation { target: root; property: "_pulse"; to: 0.8; duration: 120; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "_pulse"; to: 0; duration: 170; easing.type: Easing.InQuad }
    }

    HoverHandler {
        id: sphereHover
        enabled: root.interactive
        cursorShape: Qt.PointingHandCursor
    }
    readonly property bool _insideCircle: sphereHover.hovered &&
        Math.hypot(sphereHover.point.position.x - width / 2,
                   sphereHover.point.position.y - height / 2) <= radius
    on_InsideCircleChanged: {
        hovered = _insideCircle;
        _hover = _insideCircle ? 1 : 0;
        if (_insideCircle) {
            _dir = Math.random() * Math.PI * 2;
            _phaseT = 0;
            _phaseDur = 2.2 + Math.random() * 0.8;
            _peak = 550 + Math.random() * 250;
        }
    }
    TapHandler {
        enabled: root.interactive
        // Easter egg hook — for now, a playful heartbeat.
        onTapped: heartbeat.restart()
    }

    // Per-frame tiered segments: [ax, ay, bx, by, ...] groups per
    // depth tier, stroked by the Canvas on paint. 8 fine tiers make
    // rim transitions visually continuous.
    property var _tiers: [[], [], [], [], [], [], [], []]

    Component.onCompleted: {
        _geo = _buildGeometry(subdivisions);
        _baseVerts = _geo.cents;
        _edges = _geo.edges;
        _tick(0);
    }

    function _buildGeometry(F) {
        const PHI = (1 + Math.sqrt(5)) / 2;
        const base = [
            [-1, PHI, 0], [1, PHI, 0], [-1, -PHI, 0], [1, -PHI, 0],
            [0, -1, PHI], [0, 1, PHI], [0, -1, -PHI], [0, 1, -PHI],
            [PHI, 0, -1], [PHI, 0, 1], [-PHI, 0, -1], [-PHI, 0, 1]
        ];
        const verts = [];
        for (var i = 0; i < 12; i++) {
            var l0 = Math.hypot(base[i][0], base[i][1], base[i][2]);
            verts.push([base[i][0] / l0, base[i][1] / l0, base[i][2] / l0]);
        }
        const icosaFaces = [
            [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
            [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
            [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
            [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]
        ];
        const midCache = {};
        function edgePoint(a, b, i) {
            var key = a < b ? a + "-" + b + "-" + i : b + "-" + a + "-" + (F - i);
            if (midCache[key] !== undefined) return midCache[key];
            var va = verts[a], vb = verts[b];
            var x = (va[0] * (F - i) + vb[0] * i) / F;
            var y = (va[1] * (F - i) + vb[1] * i) / F;
            var z = (va[2] * (F - i) + vb[2] * i) / F;
            var l = Math.hypot(x, y, z);
            verts.push([x / l, y / l, z / l]);
            midCache[key] = verts.length - 1;
            return verts.length - 1;
        }
        const tris = [];
        for (var q = 0; q < icosaFaces.length; q++) {
            var fa = icosaFaces[q][0], fb = icosaFaces[q][1], fc = icosaFaces[q][2];
            var lat = {};
            var get = function (i, j) {
                var key = i + "-" + j;
                if (lat[key] !== undefined) return lat[key];
                var idx;
                if (i === 0 && j === 0) idx = fa;
                else if (i === F && j === 0) idx = fb;
                else if (i === 0 && j === F) idx = fc;
                else if (j === 0) idx = edgePoint(fa, fb, i);
                else if (i === 0) idx = edgePoint(fa, fc, j);
                else if (i + j === F) idx = edgePoint(fb, fc, j);
                else {
                    var va = verts[fa], vb = verts[fb], vc = verts[fc];
                    var k = F - i - j;
                    var x = (va[0] * k + vb[0] * i + vc[0] * j) / F;
                    var y = (va[1] * k + vb[1] * i + vc[1] * j) / F;
                    var z = (va[2] * k + vb[2] * i + vc[2] * j) / F;
                    var l = Math.hypot(x, y, z);
                    verts.push([x / l, y / l, z / l]);
                    idx = verts.length - 1;
                }
                lat[key] = idx;
                return idx;
            };
            for (var i = 0; i < F; i++)
                for (var j = 0; j < F - i; j++) {
                    tris.push([get(i, j), get(i + 1, j), get(i, j + 1)]);
                    if (j < F - i - 1)
                        tris.push([get(i, j + 1), get(i + 1, j), get(i + 1, j + 1)]);
                }
        }
        // Sphere-projected triangle centroids (dual face centers).
        const cents = [];
        for (i = 0; i < tris.length; i++) {
            var sx = 0, sy = 0, sz = 0;
            for (j = 0; j < 3; j++) {
                sx += verts[tris[i][j]][0];
                sy += verts[tris[i][j]][1];
                sz += verts[tris[i][j]][2];
            }
            var cl = Math.hypot(sx, sy, sz);
            cents.push([sx / cl, sy / cl, sz / cl]);
        }
        // Dual faces: one per primal vertex, centroid loop wound by
        // angle around the vertex direction.
        const vTris = [];
        for (i = 0; i < verts.length; i++) vTris.push([]);
        for (i = 0; i < tris.length; i++)
            for (j = 0; j < 3; j++) vTris[tris[i][j]].push(i);
        const faceCenters = [];
        for (var v = 0; v < verts.length; v++) {
            var dir = verts[v];
            var ref = Math.abs(dir[1]) < 0.9 ? [0, 1, 0] : [1, 0, 0];
            var dp = ref[0] * dir[0] + ref[1] * dir[1] + ref[2] * dir[2];
            var e1 = [ref[0] - dp * dir[0], ref[1] - dp * dir[1], ref[2] - dp * dir[2]];
            var l1 = Math.hypot(e1[0], e1[1], e1[2]);
            e1 = [e1[0] / l1, e1[1] / l1, e1[2] / l1];
            var e2 = [dir[1] * e1[2] - dir[2] * e1[1],
                      dir[2] * e1[0] - dir[0] * e1[2],
                      dir[0] * e1[1] - dir[1] * e1[0]];
            var withAng = [];
            for (i = 0; i < vTris[v].length; i++) {
                var c = cents[vTris[v][i]];
                withAng.push({ ti: vTris[v][i],
                    a: Math.atan2(c[0] * e2[0] + c[1] * e2[1] + c[2] * e2[2],
                                  c[0] * e1[0] + c[1] * e1[1] + c[2] * e1[2]) });
            }
            withAng.sort(function (p, qq) { return p.a - qq.a; });
            var loop = [];
            for (i = 0; i < withAng.length; i++) loop.push(withAng[i].ti);
            faceCenters.push(loop);
        }
        // Dual edges, deduped.
        var eset = {}, edges = [];
        for (i = 0; i < faceCenters.length; i++)
            for (j = 0; j < faceCenters[i].length; j++) {
                var p = faceCenters[i][j], r = faceCenters[i][(j + 1) % faceCenters[i].length];
                var lo = Math.min(p, r), hi = Math.max(p, r);
                var ek = lo + "-" + hi;
                if (eset[ek]) continue;
                eset[ek] = true;
                edges.push(lo, hi);
            }
        return { cents: cents, edges: edges };
    }

    function _tick(t) {
        if (!_baseVerts || _baseVerts.length === 0) return;
        var DEG = Math.PI / 180;
        var dt = _lastT < 0 ? 0 : t - _lastT;
        _lastT = t;
        if (dt < 0) dt = 0;
        if (dt > 0.1) dt = 0.1;   // frame hitches must not kick the tumble
        _t = t;

        if (hovered) {
            // One direction per phase. Speed ramps up exponentially
            // (multiple full revolutions at peak), then eases back to
            // near-basic before the next direction kicks off.
            _phaseT += dt;
            if (_phaseT >= _phaseDur) {
                var turn = (Math.PI * 0.4) + Math.random() * (Math.PI * 0.6);
                _dir += (Math.random() < 0.5 ? -turn : turn);
                _phaseT = 0;
                _phaseDur = 2.2 + Math.random() * 0.8;
                _peak = 550 + Math.random() * 250;
            }
            var ph = Math.min(1, _phaseT / _phaseDur);
            var base = 18;
            var spd;
            if (ph < 0.65) spd = base + (_peak - base) * Math.pow(ph / 0.65, 2.6);
            else {
                var u = (ph - 0.65) / 0.35;
                spd = base + (_peak - base) * Math.pow(1 - u, 1.8);
            }
            _vx = Math.cos(_dir) * spd;
            _vy = Math.sin(_dir) * spd;
        } else {
            // Unhover: exponential settle back to the calm idle spin.
            var s2 = Math.min(1, dt * 4);
            _vx += (yawRate - _vx) * s2;
            _vy += (pitchRate - _vy) * s2;
        }
        _angY += _vx * dt;
        _angP += _vy * dt;

        var sa = Math.sin(_angP * DEG), ca = Math.cos(_angP * DEG);
        var sb = Math.sin(_angY * DEG), cb = Math.cos(_angY * DEG);
        var m20 = -sb, m21 = cb * sa, m22 = cb * ca;
        var m00 = cb, m01 = sb * sa, m02 = sb * ca;
        var m10 = 0, m11 = ca, m12 = -sa;

        var npx = [], npy = [], zs = [];
        var R = (Math.min(width, height) / 2 - strokeWidth) * (1 + 0.08 * _pulse);
        for (var i = 0; i < _baseVerts.length; i++) {
            var v = _baseVerts[i];
            zs.push(m20 * v[0] + m21 * v[1] + m22 * v[2]);
            npx.push(width / 2 + (m00 * v[0] + m01 * v[1] + m02 * v[2]) * R * 0.94);
            npy.push(height / 2 - (m10 * v[0] + m11 * v[1] + m12 * v[2]) * R * 0.94);
        }
        var tiers = [[], [], [], [], [], [], [], []];
        for (var e = 0; e < _edges.length; e += 2) {
            var a = _edges[e], b = _edges[e + 1];
            var zAvg = (zs[a] + zs[b]) / 2;
            var tier = Math.floor((zAvg + 1) / 2 * 8);
            if (tier < 0) tier = 0;
            if (tier > 7) tier = 7;
            tiers[tier].push(npx[a], npy[a], npx[b], npy[b]);
        }
        _tiers = tiers;
        view.requestPaint();
    }

    onEdgeColorChanged: view.requestPaint()

    FrameAnimation {
        running: root.visible && (root.yawRate > 0 || root.pitchRate > 0)
        onTriggered: root._tick(elapsedTime)
    }

    Canvas {
        id: view
        anchors.fill: parent
        antialiasing: true

        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.lineWidth = root.strokeWidth;
            ctx.lineCap = "round";
            ctx.lineJoin = "round";
            for (var t = 0; t < 8; t++) {
                var tierAlpha = 0.12 + 0.61 * (t + 0.5) / 8;
                tierAlpha += (1 - tierAlpha) * root._hover;   // hover glow
                ctx.strokeStyle = Qt.rgba(root.edgeColor.r, root.edgeColor.g,
                                          root.edgeColor.b, tierAlpha);
                ctx.beginPath();
                var segs = root._tiers[t];
                for (var i = 0; i + 3 < segs.length; i += 4) {
                    ctx.moveTo(segs[i], segs[i + 1]);
                    ctx.lineTo(segs[i + 2], segs[i + 3]);
                }
                ctx.stroke();
            }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }
}
