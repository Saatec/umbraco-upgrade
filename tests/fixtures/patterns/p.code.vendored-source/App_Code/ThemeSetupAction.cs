using System.Xml.Linq;
using Umbraco.Core.PackageActions;

namespace SampleSite.Theme
{
    // Synthetic fixture: a package action from an imported theme.
    public class ThemeSetupAction : IPackageAction
    {
        public string Alias() => "SampleSite.ThemeSetup";
        public bool Execute(string packageName, XElement xmlData) => true;
        public bool Undo(string packageName, XElement xmlData) => true;
    }
}
