// Card runtime: uses the compiled design-system bundle when present, otherwise transpiles the component sources directly.
(function () {
  var ORDER = ['actions/Button','data/CountBubble','data/Eyebrow','data/StateLabel','data/WorkflowTrack','data/DiffStat','data/TypeIcon','data/ContextCard','data/ListRow','data/FactList',
    'feedback/Notice','feedback/Toast','feedback/Sheet','navigation/QueueButton','navigation/UsageLine','navigation/TopBar','navigation/BottomStrip',
    'decisions/DecisionRow','decisions/DropPanel','forms/Field','forms/Segmented','forms/ChoiceRow','forms/Stepper','forms/Composer'];
  function findNS() {
    for (var k in window) { try { var v = window[k]; if (v && typeof v === 'object' && v.DecisionRow && v.TopBar) return v; } catch (e) {} }
    return null;
  }
  function tryBundle(root) {
    return new Promise(function (res) { var s = document.createElement('script'); s.src = root + '_ds_bundle.js'; s.onload = res; s.onerror = res; document.head.appendChild(s); });
  }
  window.loadForge = async function (root) {
    var ns = findNS(); if (ns) return ns;
    try { var h = await fetch(root + '_ds_bundle.js', { method: 'HEAD' }); if (h.ok) { await tryBundle(root); ns = findNS(); if (ns) return ns; } } catch (e) {}
    var src = '';
    for (var i = 0; i < ORDER.length; i++) {
      var t = await (await fetch(root + 'components/' + ORDER[i] + '.jsx')).text();
      src += t.replace(/^import .*$/mg, '').replace(/^export function /mg, 'function ').replace(/^export /mg, '') + '\n';
    }
    var names = ORDER.map(function (p) { return p.split('/')[1]; }).concat(['usageColor']);
    var code = Babel.transform('window.__forgeNS = (function(){' + src + '\nreturn {' + names.join(',') + '};})();', { presets: ['react'] }).code;
    (new Function('React', code))(React);
    return window.__forgeNS;
  };
})();
