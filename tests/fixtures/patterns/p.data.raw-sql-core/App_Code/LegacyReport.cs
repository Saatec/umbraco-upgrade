namespace SampleSite.Web
{
    // Synthetic fixture: SQL against CMS internal tables with a property type ID literal.
    public static class LegacyReport
    {
        public const string Query =
            "SELECT n.text, p.dataNvarchar FROM umbracoNode n " +
            "JOIN cmsPropertyData p ON p.contentNodeId = n.id WHERE p.propertytypeid = 42";
    }
}
