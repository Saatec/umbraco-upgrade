using System.Data.Entity;

namespace SampleSite.Web
{
    // Synthetic fixture: an ORM context for a separate archive database.
    public class ArchiveContext : DbContext
    {
        public ArchiveContext() : base("name=ArchiveDb") { }

        public DbSet<ArchiveEntry> Entries { get; set; }
    }

    public class ArchiveEntry
    {
        public int Id { get; set; }
        public string Title { get; set; }
    }
}
