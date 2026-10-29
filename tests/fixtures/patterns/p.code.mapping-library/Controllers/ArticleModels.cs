namespace SampleSite.Web.Models
{
    // Synthetic fixture: a view model filled by a convention-based mapper.
    public class ArticleViewModel
    {
        public string Title { get; set; }
        public string Summary { get; set; }
    }

    public static class ArticleMapping
    {
        public static ArticleViewModel Map(dynamic content)
        {
            return content.As<ArticleViewModel>();
        }
    }
}
