const { rcedit } = require('rcedit');
(async () => {
  await rcedit('D:\\claude-desktop-portable\\Claude.exe', {
    icon: 'D:\\claude-windows-debug\\claude-logo.ico',
    'version-string': {
      ProductName: 'Claude',
      FileDescription: 'Claude Desktop (3p portable)',
      CompanyName: 'Anthropic PBC',
    },
  });
  console.log('Icon embedded into Claude.exe');
})();
