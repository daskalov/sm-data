require 'rubygems'
require 'nokogiri'
require 'open-uri'
require 'json'

## How it works
#
# 1. Get the names of all departments:
# http://explorecourses.stanford.edu/ contains links to various
# departmental pages.
#
# A list of the departments can be retrieved by:
# * get_course_headings(urls[:departments])
#
# 2. Get the courses and sections for each department
# A URL for all sections in a department can be produced by:
# * urls[:for_department][DEPARTMENT_NAME_AS_STRING]
#
# This URL leads to a page with a list of courses, where each
# course has under it a list of all sections available for that
# course throughout the academic year, grouped by semester.
#
# The sections listed by the page for any particular department
# can be retrieved by:
# * get_info(PAGE_OBTAINED_IN_STEP_2)
# which returns
# [course_hash, [section]]

urls = {
  # URL with links to courses offered by a department
  # This page is scraped to gather each department heading
  # FINANCE, MLA, etc. which can be used to produce a URL for
  # all courses and sections in that department
  :departments => "http://explorecourses.stanford.edu/",
  # A URL for some specific department
  :for_department => ->(dep) do
    "http://explorecourses.stanford.edu/print" +
    "?filter-coursestatus-Active=on"           +
    "&filter-term-Spring=on"                   +
    "&filter-term-Winter=on"                   +
    "&filter-term-Autumn=on"                   +
    "&filter-catalognumber-#{dep}=on"          +
    "&filter-catalognumber-#{dep}=on"          +
    "&q=#{dep}"                                +
    "&descriptions=on"                         +
    "&schedules=on"
  end
}

# Anchors descending from an unordered list are almost
# all the right links, save for a few empty ones at the
# end and two that don't conform to the usual convention.
# Those two do contain courses, so they could be scraped
# seperately if we're to include them too.
def get_course_headings(url)
  doc = Nokogiri::HTML(open(url))
  anchors = doc.css 'ul li a'
  # Department name useful for generating news URLs is
  # pulled from the anchor text following the pattern:
  # Department (DEPSHORTNAME)
  inners = anchors.map do |a|
    a.children.first.text =~ /\((.+)\)/
    $1.to_s
  end
  inners.reject do |i|
    i.empty? || i.split(' ').length > 1
  end
end

# Pulls all of the course info from a URL generated
# by deparment name
#
# Structure of each page:
# div#printSearchResults
#   # Each course is listed under a div.searchResult
#   div.searchResult
#     div.courseInfo
#       h2
#         span.courseNumber
#           -- Course code with trailing colon
#         span.courseTitle
#           -- Course title
#       div.courseDescription
#         -- Course description
#     div.courseAttributes
#       %% Terms, units, grading
#       %% No great uniform structure, a lot of the info
#       %% is replicated in each section description
#     div.courseAttributes
#       %% Instructors
#       %% If the prof has a page, the name is enclosed
#       %% in an anchor, otherwise it's left in-line
#     div.sectionInfo
#       div.sectionContainer
#         %% There can be multiple div.sectionContainer
#         %% elements, one for every term the course is
#         %% offered.
#         h3.sectionContainerTerm
#           -- Term
#         ul
#           li.sectionDetails
#             %% Info, seperated by pipes, littered
#             %% with various tags
#             %% end with Instructors: [instructors]
#             !! course code
#             -- units
#             -- UG reqs:
#             -- Class # X
#             -- Section Y
#             -- Grading
#             ?? CAS, INS, LEC,... <- kind ?
#             -- Date range, days, times, location, prof
#                ex: 09/24/2012 - 12/07/2012
#                    Wed, Fri 1:30 PM - 3:00 PM
#                    at GSB Gunn 102 with Admati, A. (PI)
#
# get_info(Nokogiri::XML::NodeSet) =
def get_info search_result
  # Split off each search result, which contains course
  # info and section info.
  info = search_result.css 'div.courseInfo'
  title = info.css('span.courseTitle').text
  # Shorten some commonly-seen super-long titles
  if title =~ /PhD Directed Reading/
    title = 'PhD Directed Reading'
  elsif title =~ /TGR Dissertation/
    title = 'TGR Dissertation'
  elsif title =~ /PhD Dissertation Research/
    title = 'PhD Dissertation Research'
  end
  code = info.css('span.courseNumber').text.sub(':', '')
  get_sections_info search_result, {
    code: {
      full: code
    },
    title: title
  }
end

def to_24h hour, hour_mod
  hour = hour.to_i
  hour += 12 if hour_mod =~ /PM/ && hour < 12
  hour
end

def make_days val
  {
    m: /Mon/,
    t: /Tue/,
    w: /Wed/,
    r: /Thu/,
    f: /Fri/,
    s: /Sat/,
    n: /Sun/
  }.inject({}) do |m, pair|
    k = pair.first
    v = pair[1]
    m[k] = (val =~ v) ? true : false
    m
  end
end

def term_to_semester term
  { 'Autumn' => 'F',
    'Winter' => 'W',
    'Spring' => 'S',
    'Summer' => 'E'
  }[term]
end

def get_sections_info search_result, course
  search_result
  .css('div.sectionContainer')
  .map do |term_group|
    # A term_group is:
    # * Term (ex: 2012-2013 Autumn) as an h3 title
    # * List of sections for this course for this term
    full_term = term_group.css('h3.sectionContainerTerm').text
    full_term =~ /.+\s(\w+)/
    term = $1
    term_group.css('li.sectionDetails').map do |sec|
      info = sec.text
      info = info.gsub /[\n\r]/, ''
      info =~ /(\d+) units/
      units = $1
      info =~ /Class # (\d+)/
      klass = $1
      info =~ /Section (\d+)/
      section = $1
      info =~ /Grading:\s(.*)\s\|\s(.*)\s\|/
      grading = $1
      kind = $2 ? $2.strip : ''
      time_pat = /(\d{1,2}):(\d{1,2})\s(\w{2})/
      info =~ /#{time_pat} - #{time_pat}/
      sh, sm, sp, nh, nm, np = $1, $2, $3, $4, $5, $6
      date = /\d{2}\/\d{2}\/\d{4}/
      info =~ /#{date} - #{date}(.*?)#{time_pat}/
      day = $1 ? $1.strip : ""
      info =~ /#{time_pat}\sat\s(.*?)\swith/
      loc = $4 ? $4.strip : ""
      info =~ /Instructors:(.*)$/
      profs = $1 ? $1.strip : ""
      {
        course: course.merge({
          parsed_semester: term,
          semester: term_to_semester(term)
        }),
        cid: klass,
        section: section,
        grading: grading,
        tagen: day,
        kind: kind,
        extra: {
          prof: profs,
          location: loc,
          credits: units
        },
        time: {
          days: make_days(day),
          start: {
            hour: to_24h(sh, sp),
            minute: sm.to_i,
          },
          end: {
            hour: to_24h(nh, np),
            minute: nm.to_i,
          }
        }
      }
    end
  end.flatten
end

def courses_from_sections sections
  sections.map do |s|
    course = s[:course]
    code = course[:code][:full]
    title = course[:title]
    {
      title: title,
      code: code,
      aug: "#{code} #{title}",
      semester: course[:semester]
    }
  end.uniq
end

# puts get_course_headings(urls[:departments]).join ', '
# puts urls[:for_department]['MKTG']
# puts urls[:for_department]['ACCT']

def all_sections_in fs
  fs.map do |f|
    doc = Nokogiri::HTML f
    search_results = doc.css 'div.searchResult'
    search_results.map { |r| get_info r }
  end.flatten
end

# Local files used for testing the parser without having to
# pull down live pages each time
all_sections = all_sections_in(
  ['acct', 'mktg', 'mla', 'eees']
  .map do |dep|
    File.open("data/stanford/course_#{dep}.html", 'r')
  end)

# all_sections = all_sections_in(
  # get_course_headings(urls[:departments]).map do |dep|
    # open(urls[:for_department][dep])
  # end)


# puts urls[:for_department]['MKTG']
full = {
  metadata: {
    school: {
      name: 'Stanford',
      short: 'stanford'
    },
    system: ""
  },
  data: {
    courses: courses_from_sections(all_sections),
    sections: all_sections
  }
}
puts JSON.pretty_generate full
#puts JSON.pretty_generate (courses_from_sections all_sections)
