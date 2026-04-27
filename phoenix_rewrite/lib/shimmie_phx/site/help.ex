defmodule ShimmiePhoenix.Site.Help do
  @moduledoc false

  alias Phoenix.HTML

  @topics [{"search", "Searching"}, {"licenses", "Licenses"}]

  @extensions ~w(asf avi flv gif jpg mkv mov mp4 ogv png swf webm webp zip)
  @mime_types ~w(
    application/x-shockwave-flash
    application/zip
    image/gif
    image/jpeg
    image/png
    image/webp
    video/mp4
    video/ogg
    video/quicktime
    video/webm
    video/x-flv
    video/x-matroska
    video/x-ms-asf
    video/x-msvideo
  )

  @ratings [
    %{name: "Safe", search_term: "safe", code: "s"},
    %{name: "Questionable", search_term: "questionable", code: "q"},
    %{name: "Explicit", search_term: "explicit", code: "e"},
    %{name: "Unrated", search_term: "unrated", code: "?"}
  ]

  @general_html ~S"""
  <p>Searching is largely based on tags, with a number of special keywords available that allow searching based on properties of the posts.</p>

  <div class="command_example">
  <pre>tagname</pre>
  <p>Returns posts that are tagged with "tagname".</p>
  </div>

  <div class="command_example">
  <pre>tagname othertagname</pre>
  <p>Returns posts that are tagged with "tagname" and "othertagname".</p>
  </div>

  <p>Most tags and keywords can be prefaced with a negative sign (-) to indicate that you want to search for posts that do not match something.</p>

  <div class="command_example">
  <pre>-tagname</pre>
  <p>Returns posts that are not tagged with "tagname".</p>
  </div>

  <div class="command_example">
  <pre>-tagname -othertagname</pre>
  <p>Returns posts that are not tagged with "tagname" and "othertagname". This is different than without the negative sign, as posts with "tagname" or "othertagname" can still be returned as long as the other one is not present.</p>
  </div>

  <div class="command_example">
  <pre>tagname -othertagname</pre>
  <p>Returns posts that are tagged with "tagname", but are not tagged with "othertagname".</p>
  </div>

  <p>Wildcard searches are possible as well using * for "any one, more, or none" and ? for "any one".</p>

  <div class="command_example">
  <pre>tagn*</pre>
  <p>Returns posts that are tagged with "tagname", "tagnot", or anything else that starts with "tagn".</p>
  </div>

  <div class="command_example">
  <pre>tagn?me</pre>
  <p>Returns posts that are tagged with "tagname", "tagnome", or anything else that starts with "tagn", has one character, and ends with "me".</p>
  </div>

  <div class="command_example">
  <pre>tags=1</pre>
  <p>Returns posts with exactly 1 tag.</p>
  </div>

  <div class="command_example">
  <pre>tags>0</pre>
  <p>Returns posts with 1 or more tags. </p>
  </div>

  <p>Can use &lt;, &lt;=, &gt;, &gt;=, or =.</p>

  <hr/>

  <p>Search for posts by aspect ratio</p>

  <div class="command_example">
  <pre>ratio=4:3</pre>
  <p>Returns posts with an aspect ratio of 4:3.</p>
  </div>

  <div class="command_example">
  <pre>ratio>16:9</pre>
  <p>Returns posts with an aspect ratio greater than 16:9. </p>
  </div>

  <p>Can use &lt;, &lt;=, &gt;, &gt;=, or =. The relation is calculated by dividing width by height.</p>

  <hr/>

  <p>Search for posts by file size</p>

  <div class="command_example">
  <pre>filesize=1</pre>
  <p>Returns posts exactly 1 byte in size.</p>
  </div>

  <div class="command_example">
  <pre>filesize>100mb</pre>
  <p>Returns posts greater than 100 megabytes in size. </p>
  </div>

  <p>Can use &lt;, &lt;=, &gt;, &gt;=, or =. Supported suffixes are kb, mb, and gb. Uses multiples of 1024.</p>

  <hr/>

  <p>Search for posts by MD5 hash</p>

  <div class="command_example">
  <pre>hash=0D3512CAA964B2BA5D7851AF5951F33B</pre>
  <p>Returns post with an MD5 hash 0D3512CAA964B2BA5D7851AF5951F33B.</p>
  </div>

  <hr/>

  <p>Search for posts by file name</p>

  <div class="command_example">
  <pre>filename=picasso.jpg</pre>
  <p>Returns posts that are named "picasso.jpg".</p>
  </div>

  <hr/>

  <p>Search for posts by source</p>

  <div class="command_example">
  <pre>source=https:///google.com/</pre>
  <p>Returns posts with a source of "https://google.com/".</p>
  </div>

  <div class="command_example">
  <pre>source=any</pre>
  <p>Returns posts with a source set.</p>
  </div>

  <div class="command_example">
  <pre>source=none</pre>
  <p>Returns posts without a source set.</p>
  </div>

  <hr/>

  <p>Search for posts by date posted.</p>

  <div class="command_example">
  <pre>posted>=2019-07-19</pre>
  <p>Returns posts posted on or after 2019-07-19.</p>
  </div>

  <p>Can use &lt;, &lt;=, &gt;, &gt;=, or =. Date format is yyyy-mm-dd. Date posted includes time component, so = will not work unless the time is exact.</p>

  <hr/>

  <p>Search for posts by length.</p>

  <div class="command_example">
  <pre>length>=1h</pre>
  <p>Returns posts that are longer than an hour.</p>
  </div>

  <div class="command_example">
  <pre>length<=10h15m</pre>
  <p>Returns posts that are shorter than 10 hours and 15 minutes.</p>
  </div>

  <div class="command_example">
  <pre>length>=10000</pre>
  <p>Returns posts that are longer than 10,000 milliseconds, or 10 seconds.</p>
  </div>

  <p>Can use &lt;, &lt;=, &gt;, &gt;=, or =. Available suffixes are ms, s, m, h, d, and y. A number by itself will be interpreted as milliseconds. Searches using = are not likely to work unless time is specified down to the millisecond.</p>

  <hr/>

  <p>Search for posts by dimensions</p>

  <div class="command_example">
  <pre>size=640x480</pre>
  <p>Returns posts exactly 640 pixels wide by 480 pixels high.</p>
  </div>

  <div class="command_example">
  <pre>size>1920x1080</pre>
  <p>Returns posts with a width larger than 1920 and a height larger than 1080.</p>
  </div>

  <div class="command_example">
  <pre>width=1000</pre>
  <p>Returns posts exactly 1000 pixels wide.</p>
  </div>

  <div class="command_example">
  <pre>height=1000</pre>
  <p>Returns posts exactly 1000 pixels high.</p>
  </div>

  <p>Can use &lt;, &lt;=, &gt;, &gt;=, or =.</p>

  <hr/>

  <p>Search for posts by ID</p>

  <div class="command_example">
  <pre>id=1234</pre>
  <p>Find the 1234th thing uploaded.</p>
  </div>

  <div class="command_example">
  <pre>id>1234</pre>
  <p>Find more recently posted things</p>
  </div>

  <p>Can use &lt;, &lt;=, &gt;, &gt;=, or =.</p>

  <hr/>

  <p>Sorting search results can be done using the pattern order:field_direction. _direction can be either _asc or _desc, indicating ascending (123) or descending (321) order.</p>

  <div class="command_example">
  <pre>order:id_asc</pre>
  <p>Returns posts sorted by ID, smallest first.</p>
  </div>

  <div class="command_example">
  <pre>order:width_desc</pre>
  <p>Returns posts sorted by width, largest first.</p>
  </div>

  <p>These fields are supported:
      <ul>
      <li>id</li>
      <li>width</li>
      <li>height</li>
      <li>filesize</li>
      <li>filename</li>
      </ul>
  </p>
  """

  @media_html ~S"""
  <p>Search for posts based on the type of media.</p>
  <div class="command_example">
  <pre>content:audio</pre>
  <p>Returns posts that contain audio, including videos and audio files.</p>
  </div>
  <div class="command_example">
  <pre>content:video</pre>
  <p>Returns posts that contain video, including animated GIFs.</p>
  </div>
  <p>These search terms depend on the posts being scanned for media content. Automatic scanning was implemented in mid-2019, so posts uploaded before, or posts uploaded on a system without ffmpeg, will require additional scanning before this will work.</p>
  """

  @comments_html ~S"""
  <p>Search for posts containing a certain number of comments, or comments by a particular individual.</p>
  <div class="command_example">
  <pre>comments=1</pre>
  <p>Returns posts with exactly 1 comment.</p>
  </div>
  <div class="command_example">
  <pre>comments>0</pre>
  <p>Returns posts with 1 or more comments. </p>
  </div>
  <p>Can use &lt;, &lt;=, &gt;, &gt;=, or =.</p>
  <div class="command_example">
  <pre>commented_by:username</pre>
  <p>Returns posts that have been commented on by "username". </p>
  </div>
  <div class="command_example">
  <pre>commented_by_userno:123</pre>
  <p>Returns posts that have been commented on by user 123. </p>
  </div>
  """

  @favorites_html ~S"""
  <p>Search for posts that have been favorited a certain number of times, or favorited by a particular individual.</p>
  <div class="command_example">
  <pre>favorites=1</pre>
  <p>Returns posts that have been favorited once.</p>
  </div>
  <div class="command_example">
  <pre>favorites>0</pre>
  <p>Returns posts that have been favorited 1 or more times</p>
  </div>
  <p>Can use &lt;, &lt;=, &gt;, &gt;=, or =.</p>
  <div class="command_example">
  <pre>favorited_by:username</pre>
  <p>Returns posts that have been favorited by "username". </p>
  </div>
  <div class="command_example">
  <pre>favorited_by_userno:123</pre>
  <p>Returns posts that have been favorited by user 123. </p>
  </div>
  """

  @notes_html ~S"""
  <p>Search for posts with notes.</p>
  <div class="command_example">
  <pre>note=noted</pre>
  <p>Returns posts with a note matching "noted".</p>
  </div>
  <div class="command_example">
  <pre>notes>0</pre>
  <p>Returns posts with 1 or more notes.</p>
  </div>
  <p>Can use &lt;, &lt;=, &gt;, &gt;=, or =.</p>
  <div class="command_example">
  <pre>notes_by=username</pre>
  <p>Returns posts with note(s) by "username".</p>
  </div>
  <div class="command_example">
  <pre>notes_by_user_id=123</pre>
  <p>Returns posts with note(s) by user 123.</p>
  </div>
  """

  @relationships_html ~S"""
  <p>Search for posts that have parent/child relationships.</p>
  <div class="command_example">
  <pre>parent=any</pre>
  <p>Returns posts that have a parent.</p>
  </div>
  <div class="command_example">
  <pre>parent=none</pre>
  <p>Returns posts that have no parent.</p>
  </div>
  <div class="command_example">
  <pre>parent=123</pre>
  <p>Returns posts that have image 123 set as parent.</p>
  </div>
  <div class="command_example">
  <pre>child=any</pre>
  <p>Returns posts that have at least 1 child.</p>
  </div>
  <div class="command_example">
  <pre>child=none</pre>
  <p>Returns posts that have no children.</p>
  </div>
  """

  @approval_html ~S"""
  <p>Search for posts that are approved/not approved.</p>
  <div class="command_example">
  <pre>approved:yes</pre>
  <p>Returns posts that have been approved.</p>
  </div>
  <div class="command_example">
  <pre>approved:no</pre>
  <p>Returns posts that have not been approved.</p>
  </div>
  """

  def topics, do: @topics
  def first_topic, do: @topics |> List.first() |> elem(0)

  def page(topic, opts \\ [])

  def page("search", opts) do
    current_user = Keyword.get(opts, :current_user)

    sections = [
      section("Generalmain", "General", @general_html),
      section("Mediamain", "Media", @media_html),
      section("Commentsmain", "Comments", @comments_html),
      section("File_Typesmain", "File Types", file_types_html()),
      section("Usersmain", "Users", users_html(current_user)),
      section("Favoritesmain", "Favorites", @favorites_html),
      section("Notesmain", "Notes", @notes_html),
      section("Ratingsmain", "Ratings", ratings_html()),
      section("Relationshipsmain", "Relationships", @relationships_html)
    ]

    maybe_with_approval =
      if admin?(current_user),
        do: sections ++ [section("Approvalmain", "Approval", @approval_html)],
        else: sections

    {:ok, "Searching", maybe_with_approval}
  end

  def page("licenses", _opts) do
    sections = [
      section(
        "Software_Licensesmain",
        "Software Licenses",
        "The code in Shimmie is contributed by numerous authors under multiple licenses. " <>
          "For reference, these licenses are listed below. The base software is in general licensed under the GPLv2 license."
      ),
      section("GPLv2main", "GPLv2", "<pre>#{escaped_license("gplv2.txt")}</pre>"),
      section("MITmain", "MIT", "<pre>#{escaped_license("mit.txt")}</pre>"),
      section("WTFPLmain", "WTFPL", "<pre>#{escaped_license("wtfpl.txt")}</pre>")
    ]

    {:ok, "Licenses", sections}
  end

  def page(_topic, _opts), do: :error

  defp users_html(current_user) do
    poster_ip =
      if admin?(current_user) do
        ~S"""
        <div class="command_example">
        <pre>poster_ip=127.0.0.1</pre>
        <p>Returns posts posted from IP 127.0.0.1.</p>
        </div>
        """
      else
        ""
      end

    ~S"""
    <p>Search for posts posted by particular individuals.</p>
    <div class="command_example">
    <pre>poster=username</pre>
    <p>Returns posts posted by "username".</p>
    </div>
    <div class="command_example">
    <pre>poster_id=123</pre>
    <p>Returns posts posted by user 123.</p>
    </div>
    """ <> poster_ip
  end

  defp file_types_html do
    extension_list = Enum.map_join(@extensions, "</li><li>", & &1)
    mime_list = Enum.map_join(@mime_types, "</li><li>", & &1)

    """
    <p>Search for posts by extension</p>

    <div class="command_example">
    <pre>ext=jpg</pre>
    <p>Returns posts with the extension "jpg".</p>
    </div>

    These extensions are available in the system:
    <ul><li>#{extension_list}</li></ul>

    <hr/>

    <p>Search for posts by MIME type</p>

    <div class="command_example">
    <pre>mime=image/jpeg</pre>
    <p>Returns posts that have the MIME type "image/jpeg".</p>
    </div>

    These MIME types are available in the system:
    <ul><li>#{mime_list}</li></ul>
    """
  end

  defp ratings_html do
    [first, second | _] = @ratings

    rows =
      Enum.map_join(@ratings, "", fn rating ->
        "<tr><td>#{rating.name}</td><td>#{rating.search_term}</td><td>#{rating.code}</td></tr>"
      end)

    """
    <p>Search for posts with one or more possible ratings.</p>
    <div class="command_example">
    <pre>rating:#{first.search_term}</pre>
    <p>Returns posts with the #{first.name} rating.</p>
    </div>
    <p>Ratings can be abbreviated to a single letter as well</p>
    <div class="command_example">
    <pre>rating:#{first.code}</pre>
    <p>Returns posts with the #{first.name} rating.</p>
    </div>
    <p>If abbreviations are used, multiple ratings can be searched for.</p>
    <div class="command_example">
    <pre>rating:#{first.code}#{second.code}</pre>
    <p>Returns posts with the #{first.name} or #{second.name} rating.</p>
    </div>
    <p>Available ratings:</p>
    <table>
    <tr><th>Name</th><th>Search Term</th><th>Abbreviation</th></tr>
    #{rows}</table>
    """
  end

  defp escaped_license(filename) do
    path = Application.app_dir(:shimmie_phx, "priv/help/#{filename}")

    case File.read(path) do
      {:ok, text} -> text |> HTML.html_escape() |> HTML.safe_to_string()
      _ -> ""
    end
  end

  defp section(id, title, body_html), do: %{id: id, title: title, body_html: body_html}

  defp admin?(%{class: class}), do: to_string(class) == "admin"
  defp admin?(_), do: false
end
