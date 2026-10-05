(function () {
  var h = location.hostname || 'localhost';
  var devServer = location.protocol === 'file:' || (location.port && location.port !== '5000');
  window.API_BASE = devServer ? 'http://' + h + ':5000' : location.origin;
})();