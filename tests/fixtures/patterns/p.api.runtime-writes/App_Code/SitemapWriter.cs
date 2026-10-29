using System.IO;
using System.Web.Hosting;

namespace SampleSite.Web
{
    // Synthetic fixture: writes a generated file into the web root.
    public static class SitemapWriter
    {
        public static void Write(string xml)
        {
            var path = HostingEnvironment.MapPath("~/sitemap.xml");
            File.WriteAllText(path, xml);
        }
    }
}
