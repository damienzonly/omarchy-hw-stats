import QtQuick

// Line/area graph over a history array. Draws the last `points` samples
// right-aligned, so a short history grows in from the right edge. An optional
// second series is drawn on top (network upload over download).
Canvas {
  id: root

  property var values: []
  property var values2: []
  property int points: 60
  // 0 = autoscale to the largest visible sample.
  property real maximum: 0
  property real minimumScale: 1
  property color color: "white"
  property color color2: "gray"
  property real fillOpacity: 0.25
  property real lineWidth: 1.25
  property color background: "transparent"
  property real radius: 2
  property bool showGrid: false
  property color gridColor: Qt.rgba(1, 1, 1, 0.08)

  readonly property real scaleMax: {
    if (maximum > 0) return maximum
    var m = minimumScale
    var a = visible1(values), b = visible1(values2)
    for (var i = 0; i < a.length; i++) if (a[i] > m) m = a[i]
    for (var j = 0; j < b.length; j++) if (b[j] > m) m = b[j]
    return m
  }

  function visible1(list) {
    if (!list || list.length === 0) return []
    return list.length > points ? list.slice(list.length - points) : list
  }

  onValuesChanged: requestPaint()
  onValues2Changed: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
  onColorChanged: requestPaint()
  onColor2Changed: requestPaint()
  onBackgroundChanged: requestPaint()

  // Collapse right-aligned buckets of `k` samples to their max, so long
  // histories draw at most ~one point per pixel without hiding spikes.
  function bucketMax(data, k) {
    if (k <= 1) return data
    var out = []
    for (var end = data.length; end > 0; end -= k) {
      var m = data[end - 1]
      for (var i = Math.max(0, end - k); i < end - 1; i++) if (data[i] > m) m = data[i]
      out.push(m)
    }
    return out.reverse()
  }

  function drawSeries(ctx, list, color) {
    var k = Math.max(1, Math.ceil(points / Math.max(1, width)))
    var data = bucketMax(visible1(list), k)
    var slots = Math.ceil(points / k)
    if (data.length < 2) return
    var step = width / Math.max(1, slots - 1)
    var x0 = width - (data.length - 1) * step
    var top = Math.max(0.0001, scaleMax)

    ctx.beginPath()
    for (var i = 0; i < data.length; i++) {
      var x = x0 + i * step
      var y = height - Math.min(1, data[i] / top) * (height - lineWidth) - lineWidth / 2
      if (i === 0) ctx.moveTo(x, y)
      else ctx.lineTo(x, y)
    }
    ctx.strokeStyle = color
    ctx.lineWidth = lineWidth
    ctx.lineJoin = "round"
    ctx.stroke()

    if (fillOpacity > 0) {
      ctx.lineTo(width, height)
      ctx.lineTo(x0, height)
      ctx.closePath()
      ctx.fillStyle = Qt.rgba(color.r, color.g, color.b, fillOpacity)
      ctx.fill()
    }
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    if (background.a > 0) {
      ctx.fillStyle = background
      ctx.beginPath()
      ctx.roundedRect(0, 0, width, height, radius, radius)
      ctx.fill()
    }
    if (showGrid) {
      ctx.strokeStyle = gridColor
      ctx.lineWidth = 1
      for (var g = 1; g < 4; g++) {
        var gy = Math.round(height * g / 4) + 0.5
        ctx.beginPath()
        ctx.moveTo(0, gy)
        ctx.lineTo(width, gy)
        ctx.stroke()
      }
    }
    drawSeries(ctx, values, color)
    drawSeries(ctx, values2, color2)
  }
}
