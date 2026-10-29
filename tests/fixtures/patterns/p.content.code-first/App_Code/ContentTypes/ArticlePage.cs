namespace SampleSite.Web.ContentTypes
{
    // Synthetic fixture: a code-first document type declaration.
    [DocumentType(Name = "Article Page", Alias = "articlePage")]
    public class ArticlePage
    {
        public string Headline { get; set; }
    }

    public class DocumentTypeAttribute : System.Attribute
    {
        public string Name { get; set; }
        public string Alias { get; set; }
    }
}
